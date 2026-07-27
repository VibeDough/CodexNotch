export async function onRequestGet({ env }) {
  const row = await env.PAGEVIEWS
    .prepare(`
      INSERT INTO counters (name, value)
      VALUES ('site', 1)
      ON CONFLICT(name) DO UPDATE SET value = value + 1
      RETURNING value
    `)
    .first();

  return Response.json(
    { views: Number(row?.value ?? 0) },
    { headers: { "Cache-Control": "no-store" } }
  );
}
