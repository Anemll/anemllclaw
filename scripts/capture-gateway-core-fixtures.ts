import { promises as fs } from "node:fs";
import path from "node:path";
import process from "node:process";
import { callGateway } from "../src/gateway/call.js";
import { GATEWAY_CLIENT_MODES, GATEWAY_CLIENT_NAMES } from "../src/utils/message-channel.js";

type ParsedArgs = {
  outDir: string;
  url?: string;
  token?: string;
  password?: string;
  timeoutMs: number;
  methods: string[];
  captureUnauthorized: boolean;
};

type GatewayFixture = {
  name: string;
  request: {
    method: string;
    params?: unknown;
    auth: "provided" | "invalid" | "none";
  };
  outcome:
    | {
        ok: true;
        payload: unknown;
      }
    | {
        ok: false;
        error: {
          message: string;
        };
      };
  capturedAt: string;
};

type FixtureIndex = {
  generatedAt: string;
  gateway: {
    url?: string;
    hasToken: boolean;
    hasPassword: boolean;
  };
  fixtures: Array<{
    name: string;
    path: string;
  }>;
};

const HOME_PATH = process.env.HOME?.trim();

function parseArgs(argv: string[]): ParsedArgs {
  const args = [...argv];
  let outDir = path.join("test", "fixtures", "gateway-core-contract");
  let url: string | undefined;
  let token: string | undefined;
  let password: string | undefined;
  let timeoutMs = 10_000;
  const methods: string[] = [];
  let captureUnauthorized = true;

  while (args.length > 0) {
    const arg = args.shift();
    if (!arg) {
      continue;
    }
    if (arg === "--out-dir") {
      const value = args.shift();
      if (!value) {
        throw new Error("Missing value for --out-dir");
      }
      outDir = value;
      continue;
    }
    if (arg === "--url") {
      const value = args.shift();
      if (!value) {
        throw new Error("Missing value for --url");
      }
      url = value;
      continue;
    }
    if (arg === "--token") {
      const value = args.shift();
      if (!value) {
        throw new Error("Missing value for --token");
      }
      token = value;
      continue;
    }
    if (arg === "--password") {
      const value = args.shift();
      if (!value) {
        throw new Error("Missing value for --password");
      }
      password = value;
      continue;
    }
    if (arg === "--timeout-ms") {
      const value = args.shift();
      const parsed = Number(value ?? "");
      if (!Number.isFinite(parsed) || parsed <= 0) {
        throw new Error("Invalid value for --timeout-ms");
      }
      timeoutMs = Math.floor(parsed);
      continue;
    }
    if (arg === "--method") {
      const value = args.shift();
      if (!value) {
        throw new Error("Missing value for --method");
      }
      methods.push(value);
      continue;
    }
    if (arg === "--no-unauthorized") {
      captureUnauthorized = false;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  return {
    outDir,
    url,
    token,
    password,
    timeoutMs,
    methods: methods.length > 0 ? methods : ["health", "status"],
    captureUnauthorized,
  };
}

function printHelp(): void {
  process.stdout.write(
    [
      "Capture OpenClaw gateway fixtures for tvOS rewrite compatibility.",
      "",
      "Usage:",
      "  node --import tsx scripts/capture-gateway-core-fixtures.ts [options]",
      "",
      "Options:",
      "  --url <ws-url>             Gateway URL (default: config-driven).",
      "  --token <token>            Gateway token for authenticated calls.",
      "  --password <password>      Gateway password for authenticated calls.",
      "  --method <name>            Method to capture (repeatable).",
      "  --timeout-ms <ms>          Request timeout (default: 10000).",
      "  --out-dir <path>           Output directory (default: test/fixtures/gateway-core-contract).",
      "  --no-unauthorized          Skip unauthorized fixture capture.",
      "",
    ].join("\n"),
  );
}

function sanitizeFixtureName(name: string): string {
  return name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function sanitizeStringValue(value: string): string {
  let sanitized = value;
  if (HOME_PATH && HOME_PATH.length > 0) {
    sanitized = sanitized.split(HOME_PATH).join("<HOME>");
  }
  sanitized = sanitized.replace(/\/Users\/[^/\s]+/g, "/Users/<user>");
  sanitized = sanitized.replace(/\/home\/[^/\s]+/g, "/home/<user>");
  return sanitized;
}

function normalizeValue(value: unknown, parentKey?: string): unknown {
  if (typeof value === "string") {
    if (parentKey === "capturedAt" || parentKey === "generatedAt") {
      return "<timestamp>";
    }
    return sanitizeStringValue(value);
  }
  if (typeof value === "number") {
    if (parentKey === "ts") {
      return 0;
    }
    return value;
  }
  if (Array.isArray(value)) {
    return value.map((item) => normalizeValue(item));
  }
  if (value && typeof value === "object") {
    const normalized: Record<string, unknown> = {};
    for (const [key, nested] of Object.entries(value)) {
      normalized[key] = normalizeValue(nested, key);
    }
    return normalized;
  }
  return value;
}

async function captureSuccessFixture(params: {
  name: string;
  method: string;
  callParams?: unknown;
  url?: string;
  token?: string;
  password?: string;
  timeoutMs: number;
}): Promise<GatewayFixture> {
  const payload = await callGateway({
    url: params.url,
    token: params.token,
    password: params.password,
    method: params.method,
    params: params.callParams,
    timeoutMs: params.timeoutMs,
    clientName: GATEWAY_CLIENT_NAMES.CLI,
    mode: GATEWAY_CLIENT_MODES.CLI,
  });
  return {
    name: params.name,
    request: {
      method: params.method,
      ...(params.callParams !== undefined ? { params: params.callParams } : {}),
      auth: params.token || params.password ? "provided" : "none",
    },
    outcome: { ok: true, payload },
    capturedAt: new Date().toISOString(),
  };
}

async function captureErrorFixture(params: {
  name: string;
  method: string;
  callParams?: unknown;
  url?: string;
  token?: string;
  password?: string;
  timeoutMs: number;
  authMode: "provided" | "invalid" | "none";
}): Promise<GatewayFixture> {
  try {
    await callGateway({
      url: params.url,
      token: params.token,
      password: params.password,
      method: params.method,
      params: params.callParams,
      timeoutMs: params.timeoutMs,
      clientName: GATEWAY_CLIENT_NAMES.CLI,
      mode: GATEWAY_CLIENT_MODES.CLI,
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : `Unknown error: ${JSON.stringify(error)}`;
    return {
      name: params.name,
      request: {
        method: params.method,
        ...(params.callParams !== undefined ? { params: params.callParams } : {}),
        auth: params.authMode,
      },
      outcome: {
        ok: false,
        error: { message },
      },
      capturedAt: new Date().toISOString(),
    };
  }

  throw new Error(`Expected fixture "${params.name}" to fail, but request succeeded.`);
}

async function writeFixtureFile(outDir: string, fixture: GatewayFixture): Promise<string> {
  const fileName = `${sanitizeFixtureName(fixture.name)}.json`;
  const filePath = path.join(outDir, fileName);
  const normalized = normalizeValue(fixture) as GatewayFixture;
  await fs.writeFile(filePath, `${JSON.stringify(normalized, null, 2)}\n`, "utf8");
  return path.relative(process.cwd(), filePath);
}

async function main() {
  const parsed = parseArgs(process.argv.slice(2));
  await fs.mkdir(parsed.outDir, { recursive: true });

  const fixtures: GatewayFixture[] = [];

  for (const method of parsed.methods) {
    const fixture = await captureSuccessFixture({
      name: `${method}.success`,
      method,
      url: parsed.url,
      token: parsed.token,
      password: parsed.password,
      timeoutMs: parsed.timeoutMs,
    });
    fixtures.push(fixture);
  }

  const methodNotFound = await captureErrorFixture({
    name: "unknown-method.error",
    method: "__gateway_core_contract_unknown_method__",
    url: parsed.url,
    token: parsed.token,
    password: parsed.password,
    timeoutMs: parsed.timeoutMs,
    authMode: parsed.token || parsed.password ? "provided" : "none",
  });
  fixtures.push(methodNotFound);

  if (parsed.captureUnauthorized && (parsed.token || parsed.password)) {
    const unauthorized = await captureErrorFixture({
      name: "health.unauthorized.error",
      method: "health",
      url: parsed.url,
      token: parsed.token ? `${parsed.token}-invalid` : undefined,
      password: parsed.password ? `${parsed.password}-invalid` : undefined,
      timeoutMs: parsed.timeoutMs,
      authMode: "invalid",
    });
    fixtures.push(unauthorized);
  }

  const index: FixtureIndex = {
    generatedAt: "<timestamp>",
    gateway: {
      ...(parsed.url ? { url: parsed.url } : {}),
      hasToken: Boolean(parsed.token),
      hasPassword: Boolean(parsed.password),
    },
    fixtures: [],
  };

  for (const fixture of fixtures) {
    const filePath = await writeFixtureFile(parsed.outDir, fixture);
    index.fixtures.push({
      name: fixture.name,
      path: filePath,
    });
  }

  const indexPath = path.join(parsed.outDir, "index.json");
  const normalizedIndex = normalizeValue(index) as FixtureIndex;
  await fs.writeFile(indexPath, `${JSON.stringify(normalizedIndex, null, 2)}\n`, "utf8");

  process.stdout.write(
    `Captured ${fixtures.length} fixtures to ${parsed.outDir}\nIndex: ${indexPath}\n`,
  );
}

await main();
