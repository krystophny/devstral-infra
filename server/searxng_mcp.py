#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser


USER_AGENT = "devstral-infra-searxng-mcp/1.0"
DEFAULT_LIMIT = 8
DEFAULT_TIMEOUT = 20.0
DEFAULT_FETCH_CHARS = 12000
BLOCK_TAGS = {
    "article",
    "aside",
    "br",
    "div",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "footer",
    "li",
    "main",
    "nav",
    "ol",
    "p",
    "pre",
    "section",
    "table",
    "tr",
    "td",
    "th",
    "ul",
}


class ToolError(Exception):
    pass


class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self._skip_depth = 0
        self._title_parts = []
        self._text_parts = []
        self._in_title = False

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "noscript"}:
            self._skip_depth += 1
            return
        if tag == "title":
            self._in_title = True
        if tag in BLOCK_TAGS:
            self._text_parts.append("\n")

    def handle_endtag(self, tag):
        if tag in {"script", "style", "noscript"} and self._skip_depth:
            self._skip_depth -= 1
            return
        if tag == "title":
            self._in_title = False
        if tag in BLOCK_TAGS:
            self._text_parts.append("\n")

    def handle_data(self, data):
        if self._skip_depth:
            return
        if self._in_title:
            self._title_parts.append(data)
        self._text_parts.append(data)

    @property
    def title(self):
        return normalize_text(" ".join(self._title_parts))

    @property
    def text(self):
        return normalize_text("".join(self._text_parts))


def normalize_text(value):
    value = value.replace("\r", "\n")
    value = re.sub(r"[ \t\f\v]+", " ", value)
    value = re.sub(r"\n\s*\n\s*\n+", "\n\n", value)
    return value.strip()


def clamp_int(value, default, minimum, maximum):
    try:
        value = int(value)
    except (TypeError, ValueError):
        return default
    return max(minimum, min(value, maximum))


class SearxngClient:
    def __init__(self, base_url, timeout):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def search(self, query, limit=DEFAULT_LIMIT, categories=None, language=None, time_range=None):
        params = {
            "q": query,
            "format": "json",
        }
        if categories:
            params["categories"] = ",".join(categories)
        if language:
            params["language"] = language
        if time_range:
            params["time_range"] = time_range
        payload = self._get_json("/search", params)
        return format_search_results(query, payload, limit)

    def fetch(self, url, max_chars=DEFAULT_FETCH_CHARS):
        request = urllib.request.Request(
            url,
            headers={"User-Agent": USER_AGENT, "Accept": "text/html,text/plain;q=0.9,*/*;q=0.1"},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                content_type = response.headers.get("Content-Type", "")
                body = response.read()
        except urllib.error.HTTPError as exc:
            raise ToolError(f"fetch failed with HTTP {exc.code} for {url}") from exc
        except urllib.error.URLError as exc:
            raise ToolError(f"fetch failed for {url}: {exc.reason}") from exc

        text = body.decode("utf-8", errors="replace")
        if "html" in content_type.lower() or text.lstrip().startswith("<"):
            parser = TextExtractor()
            parser.feed(text)
            title = parser.title
            body_text = parser.text
        else:
            title = ""
            body_text = normalize_text(text)

        if not body_text:
            raise ToolError(f"no readable text extracted from {url}")

        body_text = body_text[:max_chars].rstrip()
        lines = [f"URL: {url}"]
        if title:
            lines.append(f"Title: {title}")
        lines.extend(["", body_text])
        return "\n".join(lines).strip()

    def _get_json(self, path, params):
        url = f"{self.base_url}{path}?{urllib.parse.urlencode(params)}"
        request = urllib.request.Request(
            url,
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise ToolError(f"SearXNG request failed with HTTP {exc.code}: {url}") from exc
        except urllib.error.URLError as exc:
            raise ToolError(f"SearXNG request failed: {exc.reason}") from exc
        except json.JSONDecodeError as exc:
            raise ToolError(f"SearXNG returned invalid JSON for {url}") from exc


def format_search_results(query, payload, limit):
    answers = payload.get("answers") or []
    suggestions = payload.get("suggestions") or []
    results = payload.get("results") or []
    results = results[:limit]

    lines = [f"Query: {query}"]
    if answers:
        lines.append("")
        lines.append("Answers:")
        for answer in answers[:3]:
            lines.append(f"- {normalize_text(str(answer))}")
    if suggestions:
        lines.append("")
        lines.append("Suggestions:")
        for suggestion in suggestions[:5]:
            lines.append(f"- {normalize_text(str(suggestion))}")
    lines.append("")
    lines.append(f"Results: {len(results)}")

    if not results:
        lines.append("No results.")
        return "\n".join(lines)

    for index, item in enumerate(results, start=1):
        title = normalize_text(item.get("title") or item.get("url") or f"Result {index}")
        url = item.get("url") or ""
        engine = item.get("engine") or ""
        category = item.get("category") or ""
        published = item.get("publishedDate") or ""
        snippet = normalize_text(item.get("content") or item.get("snippet") or "")
        lines.append("")
        lines.append(f"{index}. {title}")
        if url:
            lines.append(f"URL: {url}")
        meta = ", ".join(part for part in (engine, category, published) if part)
        if meta:
            lines.append(f"Meta: {meta}")
        if snippet:
            lines.append(f"Snippet: {snippet[:500]}")

    return "\n".join(lines)


def response_ok(request_id, result):
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def response_error(request_id, code, message):
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message},
    }


def write_message(payload):
    data = json.dumps(payload).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii"))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in {b"\r\n", b"\n"}:
            break
        name, _, value = line.decode("utf-8").partition(":")
        headers[name.strip().lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    if length <= 0:
        return None
    body = sys.stdin.buffer.read(length)
    if not body:
        return None
    return json.loads(body.decode("utf-8"))


def tool_list():
    return {
        "tools": [
            {
                "name": "searxng_search",
                "description": "Search the configured SearXNG instance and return formatted web results.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "Search query"},
                        "limit": {
                            "type": "integer",
                            "description": "Maximum results to return",
                            "default": DEFAULT_LIMIT,
                        },
                        "categories": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "Optional SearXNG categories",
                        },
                        "language": {
                            "type": "string",
                            "description": "Optional SearXNG language code",
                        },
                        "time_range": {
                            "type": "string",
                            "description": "Optional SearXNG time range such as day, month, or year",
                        },
                    },
                    "required": ["query"],
                },
            },
            {
                "name": "searxng_fetch",
                "description": "Fetch a URL directly and return readable page text.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "url": {"type": "string", "description": "URL to fetch"},
                        "max_chars": {
                            "type": "integer",
                            "description": "Maximum characters to return",
                            "default": DEFAULT_FETCH_CHARS,
                        },
                    },
                    "required": ["url"],
                },
            },
        ]
    }


def handle_request(client, message):
    request_id = message.get("id")
    method = message.get("method")
    params = message.get("params") or {}

    try:
        if method == "initialize":
            return response_ok(
                request_id,
                {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "searxng-mcp", "version": "0.1.0"},
                },
            )
        if method == "ping":
            return response_ok(request_id, {})
        if method == "tools/list":
            return response_ok(request_id, tool_list())
        if method == "tools/call":
            name = params.get("name")
            arguments = params.get("arguments") or {}
            if name == "searxng_search":
                query = (arguments.get("query") or "").strip()
                if not query:
                    raise ToolError("query is required")
                text = client.search(
                    query=query,
                    limit=clamp_int(arguments.get("limit"), DEFAULT_LIMIT, 1, 20),
                    categories=arguments.get("categories"),
                    language=arguments.get("language"),
                    time_range=arguments.get("time_range"),
                )
            elif name == "searxng_fetch":
                url = (arguments.get("url") or "").strip()
                if not url:
                    raise ToolError("url is required")
                text = client.fetch(
                    url=url,
                    max_chars=clamp_int(arguments.get("max_chars"), DEFAULT_FETCH_CHARS, 500, 50000),
                )
            else:
                return response_error(request_id, -32602, f"unknown tool: {name}")
            return response_ok(request_id, {"content": [{"type": "text", "text": text}]})
        if method in {"notifications/initialized", "logging/setLevel"}:
            return None
        return response_error(request_id, -32601, f"method not found: {method}")
    except ToolError as exc:
        return response_error(request_id, -32000, str(exc))
    except Exception as exc:
        return response_error(request_id, -32603, str(exc))


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--base-url",
        default=os.environ.get("SEARXNG_BASE_URL", "http://192.168.1.1:8888"),
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=float(os.environ.get("SEARXNG_TIMEOUT", DEFAULT_TIMEOUT)),
    )
    return parser.parse_args()


def main():
    args = parse_args()
    client = SearxngClient(args.base_url, args.timeout)
    while True:
        message = read_message()
        if message is None:
            break
        response = handle_request(client, message)
        if response is not None and message.get("id") is not None:
            write_message(response)


if __name__ == "__main__":
    main()
