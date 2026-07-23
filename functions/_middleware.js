/* ═══════════════════════════════════════════════════════════════════════
   VendaJá — Cloudflare Worker (entry point)

   SERVE os ficheiros estáticos (index.html, loja.html) E injeta
   Open Graph tags personalizadas por loja/produto antes de devolver
   o HTML ao crawler do WhatsApp/Facebook/Instagram.

   Formato: Cloudflare Worker ESM (export default { fetch })
   ═══════════════════════════════════════════════════════════════════════ */

const SUPABASE_URL = 'https://slnoutmepcxqhjibxlxm.supabase.co';
const SUPABASE_KEY = 'sb_publishable_pxnyQopNvNHnzrL38SGiFg_SXF7JPX3';

/* ── Utilitários ── */
function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function safeImg(u) {
  const s = String(u || '').trim();
  return /^https?:\/\//i.test(s) ? s : '';
}
function clamp(s, n) {
  s = String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n - 1).trimEnd() + '…' : s;
}

/* ── Busca dados ao Supabase ── */
async function sbGet(path) {
  try {
    const r = await fetch(SUPABASE_URL + '/rest/v1/' + path, {
      headers: { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + SUPABASE_KEY },
      cf: { cacheTtl: 60, cacheEverything: true },
    });
    if (!r.ok) return null;
    const arr = await r.json();
    return Array.isArray(arr) && arr.length ? arr[0] : null;
  } catch (e) { return null; }
}

/* ── Gera bloco de OG tags ── */
async function buildOgTags(slug, produtoId, pageUrl) {
  const store = await sbGet(
    'stores?slug=eq.' + encodeURIComponent(slug) +
    '&is_published=eq.true&select=name,theme,is_suspended&limit=1'
  );
  if (!store) return null;

  const ed    = ((store.theme || {}).editor) || {};
  const hdr   = ed.header || {};
  const hero  = ed.hero   || {};

  const storeName = (hdr.logoText || store.name || 'Loja').trim();
  let ogTitle = storeName + ' — VendaJá';
  let ogDesc  = clamp(hero.subtitle || hero.title || ('Compra em ' + storeName + ' com pagamento na entrega.'), 160);
  let ogImage = safeImg(hero.bgImage) || safeImg(hdr.logoImg);
  let ogType  = 'website';

  if (produtoId) {
    const prod = await sbGet(
      'products?id=eq.' + encodeURIComponent(produtoId) +
      '&select=name,description,images,price&limit=1'
    );
    if (prod && prod.name) {
      ogType  = 'product';
      const preco = prod.price != null ? (Number(prod.price).toLocaleString('pt') + ' MT') : '';
      ogTitle = prod.name + (preco ? ' — ' + preco : '') + ' | ' + storeName;
      ogDesc  = clamp(prod.description || ('Compra ' + prod.name + ' em ' + storeName + '. Pagamento na entrega.'), 160);
      const img = Array.isArray(prod.images) && prod.images[0] ? prod.images[0] : '';
      ogImage = safeImg(img) || ogImage;
    }
  }

  const twCard = ogImage ? 'summary_large_image' : 'summary';
  let tags =
    '<meta name="description" content="'    + esc(ogDesc)   + '">' +
    '<meta property="og:type" content="'    + esc(ogType)   + '">' +
    '<meta property="og:site_name" content="VendaJá">'              +
    '<meta property="og:title" content="'   + esc(ogTitle)  + '">' +
    '<meta property="og:description" content="' + esc(ogDesc) + '">' +
    '<meta property="og:url" content="'     + esc(pageUrl)  + '">' +
    '<meta name="twitter:card" content="'   + twCard        + '">' +
    '<meta name="twitter:title" content="'  + esc(ogTitle)  + '">' +
    '<meta name="twitter:description" content="' + esc(ogDesc) + '">';
  if (ogImage) {
    tags +=
      '<meta property="og:image" content="'   + esc(ogImage) + '">' +
      '<meta name="twitter:image" content="'  + esc(ogImage) + '">';
  }
  return { tags, ogTitle };
}

/* ── Worker entry point ── */
export default {
  async fetch(request, env, ctx) {
    const url  = new URL(request.url);
    const slug = url.searchParams.get('loja');
    const prod = url.searchParams.get('produto');

    /* Passa tudo que não seja GET de HTML para o comportamento padrão */
    if (request.method !== 'GET') {
      return fetch(request);
    }

    /* Serve os ficheiros estáticos a partir do KV (Workers Sites) ou
       faz fetch ao próprio origin sem OG se não houver ?loja= */
    if (!slug) {
      return fetch(request);
    }

    /* Há ?loja= — vai buscar o HTML base e injeta OG */
    const baseUrl  = new URL(request.url);
    baseUrl.search = '';                          // sem query string — pede o HTML limpo
    const baseReq  = new Request(baseUrl.toString(), { headers: request.headers });
    const response = await fetch(baseReq);

    const ct = response.headers.get('content-type') || '';
    if (!ct.includes('text/html')) return response;

    /* Gera as OG tags; se falhar (loja não existe/Supabase down) devolve HTML sem alterações */
    const ogData = await buildOgTags(slug, prod, url.toString());
    if (!ogData) return response;

    const { tags, ogTitle } = ogData;

    /* HTMLRewriter: remove OG por omissão, corrige <title>, injeta novas tags */
    const rewriter = new HTMLRewriter()
      .on('meta[property^="og:"]',   { element(el) { el.remove(); } })
      .on('meta[name^="twitter:"]',  { element(el) { el.remove(); } })
      .on('meta[name="description"]',{ element(el) { el.remove(); } })
      .on('title',  { element(el) { el.setInnerContent(ogTitle); } })
      .on('head',   { element(el) { el.append(tags, { html: true }); } });

    const out     = rewriter.transform(response);
    const headers = new Headers(out.headers);
    headers.set('cache-control', 'public, max-age=60, s-maxage=300');
    return new Response(out.body, { status: out.status, headers });
  }
};
