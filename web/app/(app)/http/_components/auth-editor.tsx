"use client";

import { Field, TextInput } from "@/components/ui/primitives";
import type { AuthConfig, AuthType } from "@/lib/api/http-client-hooks";

const AUTH_LABELS: Record<AuthType, string> = {
  inherit: "Inherit from parent",
  none: "No auth",
  bearer: "Bearer Token",
  basic: "Basic Auth",
  apikey: "API Key",
  oauth2: "OAuth 2.0 (Client Credentials)",
};

export function describeAuth(auth: AuthConfig): string {
  return AUTH_LABELS[auth.type] ?? auth.type;
}

export function AuthEditor({
  value,
  onChange,
  allowInherit,
  inheritedSummary,
}: {
  value: AuthConfig;
  onChange: (next: AuthConfig) => void;
  allowInherit: boolean;
  inheritedSummary?: string;
}) {
  const options: AuthType[] = allowInherit
    ? ["inherit", "none", "bearer", "basic", "apikey", "oauth2"]
    : ["none", "bearer", "basic", "apikey", "oauth2"];

  const setType = (type: AuthType) => {
    if (type === "oauth2") {
      onChange({
        ...value,
        type,
        oauth2: value.oauth2 ?? { grant_type: "client_credentials", token_url: "", client_id: "", client_secret: "" },
      });
      return;
    }
    if (type === "apikey") {
      onChange({
        ...value,
        type,
        api_key_in: value.api_key_in ?? "header",
        api_key_name: value.api_key_name ?? "X-API-Key",
      });
      return;
    }
    onChange({ ...value, type });
  };

  return (
    <div className="flex flex-col gap-3">
      <Field label="Authentication method">
        <select
          aria-label="Authentication method"
          value={value.type}
          onChange={(e) => setType(e.target.value as AuthType)}
          className="h-[32px] w-full rounded-md border border-border-strong bg-surface px-2.5 text-13 text-fg focus:border-accent focus:outline-none"
        >
          {options.map((t) => (
            <option key={t} value={t}>
              {AUTH_LABELS[t]}
            </option>
          ))}
        </select>
      </Field>

      {value.type === "inherit" && (
        <div className="rounded-lg border border-border-subtle bg-sidebar px-3 py-2.5 text-12 text-fg-secondary">
          {inheritedSummary ?? "Inherits authentication from its parent folder or workspace."}
        </div>
      )}

      {value.type === "bearer" && (
        <Field label="Bearer token" hint="Supports {{variable}} or {{secret:handle}} placeholders">
          <TextInput
            mono
            value={value.token ?? ""}
            placeholder="{{api_token}}"
            onChange={(e) => onChange({ ...value, token: e.target.value })}
          />
        </Field>
      )}

      {value.type === "basic" && (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label="Username">
            <TextInput
              mono
              value={value.username ?? ""}
              placeholder="{{basic_user}}"
              onChange={(e) => onChange({ ...value, username: e.target.value })}
            />
          </Field>
          <Field label="Password">
            <TextInput
              mono
              type="password"
              value={value.password ?? ""}
              placeholder="{{basic_pass}}"
              onChange={(e) => onChange({ ...value, password: e.target.value })}
            />
          </Field>
        </div>
      )}

      {value.type === "apikey" && (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <Field label="Key name">
            <TextInput
              mono
              value={value.api_key_name ?? ""}
              placeholder="X-API-Key"
              onChange={(e) => onChange({ ...value, api_key_name: e.target.value })}
            />
          </Field>
          <Field label="Value">
            <TextInput
              mono
              value={value.api_key_value ?? ""}
              placeholder="{{api_key}}"
              onChange={(e) => onChange({ ...value, api_key_value: e.target.value })}
            />
          </Field>
          <Field label="Placement">
            <select
              aria-label="API key placement"
              value={value.api_key_in ?? "header"}
              onChange={(e) => onChange({ ...value, api_key_in: e.target.value as "header" | "query" })}
              className="h-[30px] w-full rounded-md border border-border-strong bg-surface px-2 text-13 text-fg focus:border-accent focus:outline-none"
            >
              <option value="header">Header</option>
              <option value="query">Query parameter</option>
            </select>
          </Field>
        </div>
      )}

      {value.type === "oauth2" && (
        <div className="flex flex-col gap-3">
          <Field label="Access token URL" hint="External HTTPS token endpoint (supports {{base_url}})">
            <TextInput
              mono
              value={value.oauth2?.token_url ?? ""}
              placeholder="{{auth_url}}/oauth/token"
              onChange={(e) =>
                onChange({ ...value, oauth2: { ...value.oauth2, grant_type: "client_credentials", token_url: e.target.value } })
              }
            />
          </Field>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <Field label="Client ID">
              <TextInput
                mono
                value={value.oauth2?.client_id ?? ""}
                placeholder="{{oauth_client_id}}"
                onChange={(e) =>
                  onChange({ ...value, oauth2: { ...value.oauth2, grant_type: "client_credentials", client_id: e.target.value } })
                }
              />
            </Field>
            <Field label="Client Secret">
              <TextInput
                mono
                type="password"
                value={value.oauth2?.client_secret ?? ""}
                placeholder="{{oauth_client_secret}}"
                onChange={(e) =>
                  onChange({ ...value, oauth2: { ...value.oauth2, grant_type: "client_credentials", client_secret: e.target.value } })
                }
              />
            </Field>
          </div>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <Field label="Scope (optional)">
              <TextInput
                mono
                value={value.oauth2?.scope ?? ""}
                placeholder="read:all"
                onChange={(e) =>
                  onChange({ ...value, oauth2: { ...value.oauth2, grant_type: "client_credentials", scope: e.target.value } })
                }
              />
            </Field>
            <Field label="Audience (optional)">
              <TextInput
                mono
                value={value.oauth2?.audience ?? ""}
                placeholder="https://api.example.com"
                onChange={(e) =>
                  onChange({ ...value, oauth2: { ...value.oauth2, grant_type: "client_credentials", audience: e.target.value } })
                }
              />
            </Field>
          </div>
        </div>
      )}
    </div>
  );
}
