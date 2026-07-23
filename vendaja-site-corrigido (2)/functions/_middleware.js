/* ═══════════════════════════════════════════════════════════════════════
   VendaJá — Open Graph no edge (Cloudflare Pages Function)

   O QUE FAZ
   Quando alguém partilha o link de uma loja (…/?loja=slug) ou de um produto
   (…/?loja=slug&produto=id) no WhatsApp / Facebook / Instagram, o "crawler"
   dessas plataformas NÃO executa JavaScript — por isso nunca via título,
   descrição nem imagem (o render da loja é feito no browser, do lado do cliente).

   Esta função corre no edge da Cloudflare ANTES de a página chegar ao crawler:
   vai buscar os dados da loja/produto ao Supabase (chave publishable, pública e
   segura) e reescreve o <head> do HTML com as meta tags Open Graph corretas.
   O resultado é uma pré-visualização rica (imagem + nome + descrição) na partilha.

   NÃO altera o comportamento normal da loja para utilizadores humanos:
   o JavaScript continua a renderizar a loja exatamente como antes.

   COMO ATIVAR
   Basta ter esta pasta `functions/` no repositório. O Cloudflare Pages deteta
   e ativa Functions automaticamente no próximo deploy. Nada mais a configurar.
   ═══════════════════════════════════════════════════════════════════════ */

const SUPABASE_URL = 'https://slnoutmepcxqhjibxlxm.supabase.co';
// Chave PUBLISHABLE (é suposto ser pública — a segurança está nas RLS policies).
const SUPABASE_KEY = 'sb_publishable_pxnyQopNvNHnzrL38SGiFg_SXF7JPX3';

// Escapa texto para ir com segurança dentro de um atributo HTML.
function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Aceita só URLs de imagem http(s) (evita injeção via campos de imagem).
function safeImg(u) {
  const s = String(u || '').trim();
  return /^https?:\/\//i.test(s) ? s : '';
}

// Corta a descrição a um tamanho razoável para pré-visualização.
function clamp(s, n) {
  s = String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n - 1).trimEnd() + '…' : s;
}

async function sbGet(path) {
  try {
    const r = await fetch(SUPABASE_URL + '/rest/v1/' + path, {
      headers: { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + SUPABASE_KEY },
      cf: { cacheTtl: 60, cacheEverything: true },
    });
    if (!r.ok) return null;
    const arr = await r.json();
    return Array.isArray(arr) && arr.length ? arr[0] : null;
  } catch (e) {
    return null;
  }
}

export async function onRequest(context) {
  const { request, next } = context;
  const url = new URL(request.url);

  // Só nos interessa a página HTML principal com uma loja no URL.
  const isHtmlPath = url.pathname === '/' || url.pathname === '/index.html';
  const slug = url.searchParams.get('loja');
  const produtoId = url.searchParams.get('produto');

  if (request.method !== 'GET' || !isHtmlPath || !slug) {
    return next();
  }

  // Obtém a resposta HTML original servida pelo Pages.
  const response = await next();
  const ct = response.headers.get('content-type') || '';
  if (!ct.includes('text/html')) return response;

  // Busca a loja (só publicadas). Se falhar, devolve a página tal como está.
  const store = await sbGet(
    'stores?slug=eq.' + encodeURIComponent(slug) +
    '&is_published=eq.true&select=name,theme,is_suspended&limit=1'
  );
  if (!store) return response;

  const theme = (store && store.theme) || {};
  const ed = theme.editor || {};
  const header = ed.header || {};
  const hero = ed.hero || {};

  const storeName = (header.logoText || store.name || 'Loja').toString().trim();
  const pageUrl = url.origin + url.pathname + url.search;

  // Valores por defeito: nível LOJA.
  let ogTitle = storeName + ' — VendaJá';
  let ogDesc = clamp(hero.subtitle || hero.title || ('Compra em ' + storeName + ' com pagamento na entrega.'), 160);
  let ogImage = safeImg(hero.bgImage) || safeImg(header.logoImg);
  let ogType = 'website';

  // Se o link aponta para um produto específico, tenta enriquecer com o produto.
  if (produtoId) {
    const prod = await sbGet(
      'products?id=eq.' + encodeURIComponent(produtoId) +
      '&select=name,description,images,price,store_id&limit=1'
    );
    if (prod && prod.name) {
      ogType = 'product';
      const preco = prod.price != null ? (Number(prod.price).toLocaleString('pt') + ' MT') : '';
      ogTitle = prod.name + (preco ? ' — ' + preco : '') + ' | ' + storeName;
      ogDesc = clamp(prod.description || ('Compra ' + prod.name + ' em ' + storeName + '. Pagamento na entrega.'), 160);
      const firstImg = Array.isArray(prod.images) && prod.images.length ? prod.images[0] : '';
      ogImage = safeImg(firstImg) || ogImage;
    }
  }

  // Monta o bloco de meta tags novo (sem duplicar — os antigos são removidos abaixo).
  const twCard = ogImage ? 'summary_large_image' : 'summary';
  let tags =
    '<meta name="description" content="' + esc(ogDesc) + '">' +
    '<meta property="og:type" content="' + esc(ogType) + '">' +
    '<meta property="og:site_name" content="VendaJá">' +
    '<meta property="og:title" content="' + esc(ogTitle) + '">' +
    '<meta property="og:description" content="' + esc(ogDesc) + '">' +
    '<meta property="og:url" content="' + esc(pageUrl) + '">' +
    '<meta name="twitter:card" content="' + twCard + '">' +
    '<meta name="twitter:title" content="' + esc(ogTitle) + '">' +
    '<meta name="twitter:description" content="' + esc(ogDesc) + '">';
  if (ogImage) {
    tags +=
      '<meta property="og:image" content="' + esc(ogImage) + '">' +
      '<meta name="twitter:image" content="' + esc(ogImage) + '">';
  }

  // Reescreve o HTML: remove as OG por omissão, corrige o <title> e injeta as novas.
  const rewriter = new HTMLRewriter()
    .on('meta[property^="og:"]', { element(el) { el.remove(); } })
    .on('meta[name^="twitter:"]', { element(el) { el.remove(); } })
    .on('meta[name="description"]', { element(el) { el.remove(); } })
    .on('title', { element(el) { el.setInnerContent(ogTitle); } })
    .on('head', { element(el) { el.append(tags, { html: true }); } });

  const out = rewriter.transform(response);
  // Cache curto no edge para aliviar o Supabase em partilhas virais.
  const headers = new Headers(out.headers);
  headers.set('cache-control', 'public, max-age=60, s-maxage=300');
  return new Response(out.body, { status: out.status, headers });
}
