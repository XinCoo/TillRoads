import test from 'node:test';
import assert from 'node:assert/strict';
import { authenticatedUserId, isAuthorized, parseTokens, requireBearer } from './auth.mjs';

test('parseTokens trims, drops empty values, and deduplicates', () => {
  assert.deepEqual(parseTokens(' alpha:user-1, beta:user-2 ,,alpha:user-1 '), [
    { token: 'alpha', userId: 'user-1' },
    { token: 'beta', userId: 'user-2' },
  ]);
  assert.deepEqual(parseTokens('missing-user, :user-3, token: '), []);
  assert.deepEqual(parseTokens(undefined), []);
});

test('Bearer authorization accepts configured token and rejects malformed or wrong tokens', () => {
  const tokens = parseTokens('alpha:user-1,beta:user-2');
  assert.equal(isAuthorized({ headers: { authorization: 'Bearer alpha' } }, tokens), true);
  assert.equal(isAuthorized({ headers: { authorization: 'bearer beta' } }, tokens), true);
  assert.equal(isAuthorized({ headers: { authorization: 'Basic alpha' } }, tokens), false);
  assert.equal(isAuthorized({ headers: { authorization: 'Bearer gamma' } }, tokens), false);
  assert.equal(isAuthorized({ headers: {} }, tokens), false);
  assert.equal(authenticatedUserId({ headers: { authorization: 'Bearer alpha' } }, tokens), 'user-1');
});

test('requireBearer throws stable 401 response', () => {
  assert.throws(
    () => requireBearer({ headers: {} }, parseTokens('secret:user-1')),
    (error) => error.statusCode === 401 && error.body.error === 'unauthorized',
  );
});
