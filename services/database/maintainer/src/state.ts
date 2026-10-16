import { readFile, writeFile, rename, mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';

export interface MaintainerState {
  /** ISO timestamp of the last time the update check ran. */
  last_check_at: string | null;

  /** last_modified of the CKAN resource we most recently downloaded. */
  last_modified_seen: string | null;

  /** The feed_version currently active in ops.feed. */
  active_feed_version: string | null;

  /**
   * A downloaded-but-not-yet-activated feed. We hold it here when its
   * start_date is further in the future than ACTIVATE_DAYS_BEFORE_START.
   */
  pending: {
    feed_version: string;
    start_date: string; // YYYY-MM-DD
    end_date: string; // YYYY-MM-DD
    zip_path: string;
  } | null;

  /** ISO timestamp of the last successful maintain tick. */
  last_maintain_at: string | null;

  /** The JSON report returned by the last ops.maintain(). */
  last_maintain_result: unknown;
}

const EMPTY: MaintainerState = {
  last_check_at: null,
  last_modified_seen: null,
  active_feed_version: null,
  pending: null,
  last_maintain_at: null,
  last_maintain_result: null,
};

export class StateStore {
  private path: string;
  private current: MaintainerState = { ...EMPTY };

  constructor(private dir: string) {
    this.path = join(dir, 'state.json');
  }

  async load(): Promise<void> {
    try {
      const raw = await readFile(this.path, 'utf8');
      const parsed = JSON.parse(raw) as Partial<MaintainerState>;
      this.current = { ...EMPTY, ...parsed };
    } catch {
      this.current = { ...EMPTY };
    }
  }

  get(): MaintainerState {
    return this.current;
  }

  async update(patch: Partial<MaintainerState>): Promise<void> {
    this.current = { ...this.current, ...patch };
    await this.persist();
  }

  private async persist(): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    const tmp = this.path + '.tmp';
    await writeFile(tmp, JSON.stringify(this.current, null, 2));
    await rename(tmp, this.path);
  }
}
