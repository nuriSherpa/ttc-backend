import type { Logger } from './logger.js';

const CKAN_BASE = 'https://ckan0.cf.opendata.inter.prod-toronto.ca';
const CKAN_ENDPOINT = `${CKAN_BASE}/api/3/action/package_show`;

export interface GtfsResource {
  name: string;
  url: string;
  last_modified: string;
  size: number;
}

interface CkanApiResponse {
  success: boolean;
  result?: {
    resources?: Array<{
      format?: string;
      name?: string;
      url?: string;
      last_modified?: string;
      size?: number | null;
    }>;
  };
}

/**
 * Fetch the CKAN package and return the ZIP resource to use.
 *
 * If `resourceNameFilter` is set, only resources whose name contains it
 * (case-insensitive) are considered. Otherwise, the largest ZIP is chosen.
 *
 * Returns null if the package has no usable ZIP resource.
 */
export async function findGtfsResource(
  pkg: string,
  resourceNameFilter: string | undefined,
  log: Logger,
): Promise<GtfsResource | null> {
  const url = `${CKAN_ENDPOINT}?id=${encodeURIComponent(pkg)}`;
  log.debug({ url }, 'querying ckan');

  const r = await fetch(url, {
    headers: { Accept: 'application/json', 'User-Agent': 'ttc-maintainer/0.1' },
  });
  if (!r.ok) throw new Error(`CKAN HTTP ${r.status}`);

  const body = (await r.json()) as CkanApiResponse;
  if (!body.success || !body.result?.resources) {
    log.warn({ body }, 'ckan response missing resources');
    return null;
  }

  let zips = body.result.resources
    .filter((x) => (x.format ?? '').toUpperCase() === 'ZIP' && x.url)
    .map<GtfsResource>((x) => ({
      name: x.name ?? '',
      url: x.url!,
      last_modified: x.last_modified ?? '',
      size: x.size ?? 0,
    }));

  if (resourceNameFilter) {
    const needle = resourceNameFilter.toLowerCase();
    zips = zips.filter((z) => z.name.toLowerCase().includes(needle));
  }

  if (zips.length === 0) return null;

  // Prefer the largest zip (the merged feed).
  zips.sort((a, b) => b.size - a.size);
  return zips[0]!;
}
