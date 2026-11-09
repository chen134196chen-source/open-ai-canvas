// @ts-nocheck
/**
 * Cloudflare Pages Functions —— 把本站 /api/* 反向代理到影策后端。
 *
 * 影策后端（Go + Gin）跑不了 Workers，所以必须放在有持久磁盘的机器上
 * （自建服务器 / VPS / Cloudflare Tunnel 指向的本机）。
 * 前端静态站点放 Pages，靠这个函数把 API 请求转过去，保持同源、免 CORS。
 *
 * 需要在 Pages 项目里配置环境变量：
 *   API_ORIGIN = https://你的后端域名      例如 https://api.example.com
 *
 * 限制（务必知道）：
 *   1. 不支持 WebSocket 升级，实时协作会退化成轮询。
 *   2. 请求体有大小上限，超大素材上传可能失败，建议后端单独给个上传域名。
 *   3. 代理会占用 Functions 配额，大流量请改用后端直连 + CORS。
 */
interface Env {
    API_ORIGIN?: string;
}

export const onRequest = async (context) => {
    const env = context.env || {};
    const origin = String(env.API_ORIGIN || "")
        .trim()
        .replace(/\/+$/, "");

    if (!origin) {
        return new Response(
            JSON.stringify({
                error: "后端未配置",
                hint: "在 Cloudflare Pages 项目 → Settings → Environment variables 添加 API_ORIGIN，值填后端域名（含 https://）",
            }),
            {
                status: 502,
                headers: { "content-type": "application/json; charset=utf-8" },
            },
        );
    }

    const incoming = new URL(context.request.url);
    let upstream;
    try {
        upstream = new URL(origin + incoming.pathname + incoming.search);
    } catch (e) {
        return new Response(
            JSON.stringify({ error: "API_ORIGIN 不是合法 URL: " + origin }),
            { status: 502, headers: { "content-type": "application/json; charset=utf-8" } },
        );
    }

    const method = context.request.method;
    const headers = new Headers(context.request.headers);
    headers.delete("host");
    headers.delete("cf-connecting-ip");
    headers.delete("cf-ipcountry");
    // 后端按自身域名判断来源时，必须把 Origin 换掉，否则会被当跨域请求拦下
    headers.set("origin", upstream.origin);
    headers.set("x-forwarded-host", incoming.host);
    headers.set("x-forwarded-proto", incoming.protocol.replace(":", ""));

    const init = {
        method,
        headers,
        redirect: "manual",
    };
    if (method !== "GET" && method !== "HEAD") {
        init.body = context.request.body;
    }

    let resp;
    try {
        resp = await fetch(upstream.toString(), init);
    } catch (e) {
        return new Response(
            JSON.stringify({
                error: "连不上后端",
                upstream: upstream.toString(),
                detail: String(e),
            }),
            { status: 502, headers: { "content-type": "application/json; charset=utf-8" } },
        );
    }

    const outHeaders = new Headers(resp.headers);
    outHeaders.delete("content-encoding");
    outHeaders.delete("content-length");
    outHeaders.delete("transfer-encoding");

    return new Response(resp.body, {
        status: resp.status,
        statusText: resp.statusText,
        headers: outHeaders,
    });
};
