/** Constants shared by the task scripts. Change them here, nowhere else. */

export const PROJECT = "Efferent";
export const SCHEME = "Efferent";
export const WORKSPACE = `${PROJECT}.xcworkspace`;

/**
 * Where `dist` leaves the unsigned archive.
 *
 * Signing, packaging and upload all happen outside this repository, and this
 * path is the whole of the agreement with whatever does them. Moving it breaks
 * that side silently, so treat it as fixed.
 */
export const ARCHIVE = `build/${PROJECT}.xcarchive`;

/**
 * xcodebuild's copy phases must find the system rsync. A Homebrew rsync earlier
 * on PATH breaks both archiving and exporting, with an error that blames the
 * copy rather than the tool.
 */
export function systemToolPath(): Record<string, string> {
  return { PATH: `/usr/bin:${Deno.env.get("PATH") ?? ""}` };
}
