// Bearer token authentication for the HTTP boundary.
import { createHash, timingSafeEqual } from 'node:crypto';

export function parseTokens(value = process.env.TOKENS) {
  if (typeof value !== 'string') return [];
  const parsed = value.split(',').map((entry) => entry.trim()).filter(Boolean).map((entry) => {
    const separator = entry.indexOf(':');
    if (separator <= 0) return null;
    const token = entry.slice(0, separator).trim();
    const userId = entry.slice(separator + 1).trim();
    if (!token || !userId) return null;
    return { token, userId };
  }).filter(Boolean);
  return [...new Map(parsed.map((entry) => [entry.token, entry])).values()];
}
function constantTimeTokenEqual(received, expected) {
  const a = createHash('sha256').update(received).digest();
  const b = createHash('sha256').update(expected).digest();
  return timingSafeEqual(a, b);
}

export function authenticatedUserId(req, tokens = parseTokens()) {
  if (!tokens.length) return undefined;
  const header = req?.headers?.authorization;
  if (typeof header !== 'string') return undefined;
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  if (!match) return undefined;
  const found = tokens.find((entry) => constantTimeTokenEqual(match[1], entry.token));
  return found?.userId;
}

export function isAuthorized(req, tokens = parseTokens()) {
  if (!tokens.length) return false;
  const header = req?.headers?.authorization;
  if (typeof header !== 'string') return false;
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return Boolean(match && tokens.some((entry) => constantTimeTokenEqual(match[1], entry.token)));
}

export function requireBearer(req, tokens = parseTokens()) {
  if (!isAuthorized(req, tokens)) {
    const error = new Error('unauthorized');
    error.statusCode = 401;
    error.body = { error: 'unauthorized' };
    throw error;
  }
  return authenticatedUserId(req, tokens);
}
