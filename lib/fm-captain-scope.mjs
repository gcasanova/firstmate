import { existsSync, lstatSync, realpathSync } from "node:fs";
import { resolve } from "node:path";

/** Returns true only for the explicitly configured, non-secondmate primary home. */
export function isConfirmedCaptainHome({ fmHome, codeRoot, stateDir }) {
  if (typeof fmHome !== "string" || !fmHome) return false;
  try {
    const home = realpathSync(resolve(fmHome));
    if (home !== realpathSync(resolve(codeRoot))) return false;
    const marker = `${home}/.fm-secondmate-home`;
    try {
      lstatSync(marker);
      return false;
    } catch (error) {
      if (!(error && typeof error === "object" && "code" in error && error.code === "ENOENT")) return false;
    }
    return existsSync(`${home}/AGENTS.md`) && existsSync(`${home}/bin`) && existsSync(stateDir);
  } catch {
    return false;
  }
}
