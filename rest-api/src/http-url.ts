export type HttpBaseUrl = { origin: string; pathname: string; href: string };

/** API endpoints only need HTTP(S) origins and a preserved deployment prefix. */
export function parseHttpBaseUrl(value: string): HttpBaseUrl {
  if (typeof URL !== "undefined") {
    const url = new URL(value);
    if (!/^https?:$/.test(url.protocol) || url.username || url.password) throw new Error("Invalid GameAlgo HTTP URL");
    return { origin: url.origin, pathname: url.pathname, href: url.href };
  }
  const match = /^(https?):\/\/([^\s/?#@]+)(\/[^?#\s]*)?(?:\?[^#\s]*)?(?:#[^\s]*)?$/i.exec(value);
  if (!match) throw new Error("Invalid GameAlgo HTTP URL");
  const protocol = match[1].toLowerCase();
  const authority = match[2].toLowerCase().replace(protocol === "https" ? /:443$/ : /:80$/, "");
  const origin = `${protocol}://${authority}`;
  const pathname = normalizePath(match[3] || "/");
  return { origin, pathname, href: origin + pathname };
}

export function resolveHttpUrl(value: string, base: HttpBaseUrl): string {
  if (typeof URL !== "undefined") return new URL(value, base.href).href;
  if (/^https?:\/\//i.test(value)) return parseHttpBaseUrl(value).href;
  if (/^[a-z][a-z0-9+.-]*:/i.test(value) || value.startsWith("//")) throw new Error("Invalid GameAlgo HTTP URL");
  const path = value.startsWith("/") ? value : base.pathname.replace(/[^/]*$/, "") + value;
  return base.origin + normalizePath(path);
}

function normalizePath(path: string): string {
  const result: string[] = [];
  for (const part of path.split("/")) {
    if (part === "..") result.pop();
    else if (part !== ".") result.push(part);
  }
  return result.join("/") || "/";
}
