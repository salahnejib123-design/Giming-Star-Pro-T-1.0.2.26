// Vercel entry point for the online API. The same handler that runs on Netlify
// (netlify/functions/api.mjs) serves every /api/* request here.
import handler from "../netlify/functions/api.mjs";

export const config = { maxDuration: 30 };

async function readBody(req) {
  if (req.method === "GET" || req.method === "HEAD") return undefined;
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks);
}

export default async function vercelApi(req, res) {
  try {
    const url = new URL(req.url, `https://${req.headers.host ?? "localhost"}`);
    const webReq = new Request(url, { method: req.method, headers: req.headers, body: await readBody(req) });
    const out = await handler(webReq);
    res.statusCode = out.status;
    out.headers.forEach((value, key) => res.setHeader(key, value));
    res.end(Buffer.from(await out.arrayBuffer()));
  } catch (e) {
    res.statusCode = 500;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: "server_error" }));
  }
}
