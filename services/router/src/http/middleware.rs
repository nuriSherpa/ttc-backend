use axum::http::HeaderMap;

use crate::http::errors::ApiError;
use crate::AppState;

pub fn check_internal_token(state: &AppState, headers: &HeaderMap) -> Result<(), ApiError> {
    let token = headers
        .get("X-Internal-Token")
        .and_then(|v| v.to_str().ok())
        .ok_or(ApiError::Unauthorized)?;
    if token != state.internal_token {
        return Err(ApiError::Unauthorized);
    }
    Ok(())
}