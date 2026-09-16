import path from "node:path";
import { noLinks, readBounded, validateResult } from "./manifest.js";

export const rejectedAnswerCharacterLimit = 65536;

export function diagnoseRejectedAnswer(answer: string, nonce: string, inputHash: string): string {
  const text = answer.trim().replace(/^FLEET_RESULT:\s*/, "");
  let value: unknown;
  try { value = JSON.parse(text); }
  catch { return "answer: expected one complete JSON object, optionally prefixed with FLEET_RESULT:"; }
  try { validateResult(value, nonce, inputHash); }
  catch (error) { return error instanceof Error ? error.message : String(error); }
  // Diagnostics never override the bridge's authoritative rejection or repair an artifact.
  return "The retained JSON matches the host field schema, but bridge framing or validation rejected it. Original rejection retained.";
}

export function readRejectedAnswer(directory: string, nonce: string, inputHash: string) {
  const file = path.join(directory, "answer.txt");
  noLinks(file);
  const retained = readBounded(file, rejectedAnswerCharacterLimit * 4);
  const answer = retained.slice(0, rejectedAnswerCharacterLimit);
  const limitReached = retained.length >= rejectedAnswerCharacterLimit;
  return {
    answer, limitReached,
    diagnostic: limitReached ? "answer: capture limit reached; retained text may be incomplete" :
      diagnoseRejectedAnswer(answer, nonce, inputHash),
  };
}

export function rejectedResultError(directory: string, nonce: string, inputHash: string): string {
  try { return readRejectedAnswer(directory, nonce, inputHash).diagnostic; }
  catch (error) {
    return `Result rejected; retained answer unavailable: ${error instanceof Error ? error.message : String(error)}`.slice(0, 1000);
  }
}
