// api/billing.js — the ONE server this architecture ever adds.
//
// Everything else in Keeping Cadence is Neon (Postgres RLS + RPC) with no
// server. Stripe is the exception BACKEND.md always called out: a webhook has to
// land somewhere, and money can't be adjudicated by a client-held JWT. This is
// that seam, and nothing more.
//
// Two actions on one Vercel Node function:
//   POST /api/billing?action=checkout  — start a subscription for a team you own
//   POST /api/billing?action=webhook   — Stripe tells us a subscription changed
//
// The paywall itself lives in Postgres (teams.plan + kc_private._guard_member_limit
// in db/schema.sql). This function's only privileged act is flipping teams.plan
// between 'free' and 'pro' in response to a *verified* Stripe event — so it uses a
// direct DATABASE_URL connection (bypassing RLS), never the user-facing Data API.
//
// SAFE BY DEFAULT: with any required env var missing it returns 501 and touches
// nothing, so deploying it before billing is configured is inert. To go live:
//   1. `npm i` (adds the deps in package.json)
//   2. set env in Vercel: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET,
//      STRIPE_PRICE_ID (a recurring price), DATABASE_URL (Neon, privileged),
//      NEON_JWKS_URL (Neon Auth JWKS), APP_URL (e.g. https://app.keepingcadence.com)
//   3. add the Stripe webhook endpoint -> https://app.keepingcadence.com/api/billing?action=webhook
//      subscribed to checkout.session.completed and customer.subscription.deleted
//
// Note: Stripe signature verification needs the RAW request body, so this
// function disables body parsing (see `config` at the bottom).

const REQUIRED = ['STRIPE_SECRET_KEY', 'STRIPE_WEBHOOK_SECRET', 'STRIPE_PRICE_ID', 'DATABASE_URL', 'NEON_JWKS_URL', 'APP_URL'];

module.exports = async (req, res) => {
  const missing = REQUIRED.filter((k) => !process.env[k]);
  if (missing.length) {
    res.status(501).json({ error: 'billing not configured', missing });
    return;
  }
  const action = new URL(req.url, 'http://localhost').searchParams.get('action');
  try {
    if (req.method === 'POST' && action === 'checkout') return await checkout(req, res);
    if (req.method === 'POST' && action === 'webhook') return await webhook(req, res);
    res.status(404).json({ error: 'unknown action' });
  } catch (e) {
    res.status(e.statusCode || 500).json({ error: e.message || 'billing error' });
  }
};

// --- helpers ----------------------------------------------------------------

function rawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

// Verify the caller's Neon Auth Data-API JWT and return its `sub` (the user id).
async function verifiedUid(req) {
  const auth = req.headers['authorization'] || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
  if (!token) { const e = new Error('missing bearer token'); e.statusCode = 401; throw e; }
  const { jwtVerify, createRemoteJWKSet } = require('jose');
  const jwks = createRemoteJWKSet(new URL(process.env.NEON_JWKS_URL));
  try {
    const { payload } = await jwtVerify(token, jwks);
    if (!payload.sub) throw new Error('no sub');
    return payload.sub;
  } catch { const e = new Error('invalid token'); e.statusCode = 401; throw e; }
}

function db() {
  const { neon } = require('@neondatabase/serverless');
  return neon(process.env.DATABASE_URL);
}

// --- checkout: start a subscription for a team the caller owns ---------------

async function checkout(req, res) {
  const uid = await verifiedUid(req);
  const body = JSON.parse((await rawBody(req)).toString('utf8') || '{}');
  const teamId = body.team_id;
  if (!teamId) { res.status(400).json({ error: 'team_id required' }); return; }

  const sql = db();
  const rows = await sql`select id from teams where id = ${teamId} and owner_id = ${uid}`;
  if (!rows.length) { res.status(403).json({ error: 'not your team' }); return; }

  const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);
  const session = await stripe.checkout.sessions.create({
    mode: 'subscription',
    line_items: [{ price: process.env.STRIPE_PRICE_ID, quantity: 1 }],
    client_reference_id: teamId,
    metadata: { team_id: teamId },
    subscription_data: { metadata: { team_id: teamId } },
    success_url: `${process.env.APP_URL}/?billing=success`,
    cancel_url: `${process.env.APP_URL}/?billing=cancel`,
  });
  res.status(200).json({ url: session.url });
}

// --- webhook: flip teams.plan on a verified subscription event --------------

async function webhook(req, res) {
  const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);
  const sig = req.headers['stripe-signature'];
  const raw = await rawBody(req);
  let event;
  try {
    event = stripe.webhooks.constructEvent(raw, sig, process.env.STRIPE_WEBHOOK_SECRET);
  } catch (e) {
    res.status(400).json({ error: `signature: ${e.message}` });
    return;
  }

  const teamOf = (obj) => (obj && obj.metadata && obj.metadata.team_id) || (obj && obj.client_reference_id) || null;
  const sql = db();

  if (event.type === 'checkout.session.completed') {
    const teamId = teamOf(event.data.object);
    if (teamId) await sql`update teams set plan = 'pro' where id = ${teamId}`;
  } else if (event.type === 'customer.subscription.deleted') {
    const teamId = teamOf(event.data.object);
    if (teamId) await sql`update teams set plan = 'free' where id = ${teamId}`;
  }
  res.status(200).json({ received: true });
}

// Stripe needs the raw body for signature verification; disable Vercel parsing.
module.exports.config = { api: { bodyParser: false } };
