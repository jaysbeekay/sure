// A small GitHub REST and GraphQL client on Node's built-in fetch, so the flow
// scripts need no npm install and add no dependency to the application.

const API = "https://api.github.com";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// The next page, rebuilt on the path that was asked for. GitHub's own Link
// header names the repository by numeric id, which some proxies refuse.
function nextPage(header, path) {
  const link = header?.split(",").find((part) => part.includes('rel="next"'))?.match(/<([^>]+)>/)?.[1];
  const page = link ? new URL(link).searchParams.get("page") : null;
  if (!page) return null;
  const url = new URL(path, API);
  url.searchParams.set("page", page);
  return url.pathname + url.search;
}

// Without a token requests go unauthenticated: fine for a local read-only dry
// run against public repositories, never used in Actions.
export function createClient(token) {

  async function request(method, path, body) {
    const url = path.startsWith("http") ? path : `${API}${path}`;
    for (let attempt = 0; ; attempt++) {
      const res = await fetch(url, {
        method,
        headers: {
          ...(token ? { authorization: `Bearer ${token}` } : {}),
          accept: "application/vnd.github+json",
          "x-github-api-version": "2022-11-28",
          "user-agent": "sure-flow",
          ...(body ? { "content-type": "application/json" } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });

      const throttled = res.status === 429 || (res.status === 403 && (res.headers.get("retry-after") || res.headers.get("x-ratelimit-remaining") === "0"));
      if ((res.status >= 500 || throttled) && attempt < 3) {
        const wait = Number(res.headers.get("retry-after")) * 1000 || 2000 * 2 ** attempt;
        await sleep(Math.min(wait, 60000));
        continue;
      }
      if (!res.ok) {
        const text = await res.text();
        const error = new Error(`${method} ${url.replace(API, "")} -> ${res.status}: ${text.slice(0, 300)}`);
        error.status = res.status;
        throw error;
      }
      return { data: res.status === 204 ? null : await res.json(), res };
    }
  }

  return {
    async rest(method, path, body) {
      return (await request(method, path, body)).data;
    },

    // Follows Link headers. Handles both plain arrays and the wrapped shape
    // of endpoints such as check-runs.
    async paginate(path) {
      const first = `${path}${path.includes("?") ? "&" : "?"}per_page=100`;
      let url = first;
      const out = [];
      while (url) {
        const { data, res } = await request("GET", url);
        out.push(...(Array.isArray(data) ? data : (data.check_runs ?? data.items ?? [])));
        url = nextPage(res.headers.get("link"), first);
      }
      return out;
    },

    async graphql(query, variables = {}) {
      const { data } = await request("POST", "/graphql", { query, variables });
      if (data.errors?.length) throw new Error(`GraphQL: ${data.errors.map((e) => e.message).join("; ")}`);
      return data.data;
    },
  };
}
