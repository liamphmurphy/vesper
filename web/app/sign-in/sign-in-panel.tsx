"use client";

import { useEffect, useState } from "react";
import { fetchAuthStatus, type AuthStatus } from "@/lib/owner-sign-in";
import { OwnerCredentialsForm } from "@/components/domain/owner-sign-in-form";
import { EmptyState, Skeleton } from "@/components/ui/primitives";

/** A full load: the app was refused before, and needs nothing from this page. */
function enterApp() {
  window.location.assign("/");
}

const signInLinkHelp = (
  <>
    Run <code className="font-mono">make signin</code> where Vesper runs and open the link it prints. Each link works once
    and keeps this browser signed in for a year.
  </>
);

export function SignInPanel({ linkFailed }: { linkFailed: boolean }) {
  const [status, setStatus] = useState<AuthStatus | "unknown" | null>(null);

  useEffect(() => {
    let live = true;
    fetchAuthStatus().then(
      (s) => live && setStatus(s),
      () => live && setStatus("unknown"),
    );
    return () => {
      live = false;
    };
  }, []);

  useEffect(() => {
    if (status !== null && status !== "unknown" && status.signed_in) enterApp();
  }, [status]);

  if (linkFailed) {
    return (
      <EmptyState icon="lock" title="That sign-in link didn't work">
        It was already used or has expired (links last 15 minutes). {signInLinkHelp}
      </EmptyState>
    );
  }
  if (status === null || (status !== "unknown" && status.signed_in)) {
    return <Skeleton className="h-48 w-[320px]" />;
  }
  if (status === "unknown" || (status.claimed && !status.password_set)) {
    return (
      <EmptyState icon="lock" title="Sign in to Vesper">
        {signInLinkHelp}
      </EmptyState>
    );
  }
  const settingUp = !status.claimed;
  return (
    <div className="flex w-full max-w-[340px] flex-col items-center gap-4">
      <EmptyState icon="lock" title={settingUp ? "Set up Vesper" : "Sign in to Vesper"} className="pb-0">
        {settingUp
          ? "Choose the username and password you'll sign in with. Use them on any other device you open Vesper from."
          : "Enter your username and password."}
      </EmptyState>
      <OwnerCredentialsForm action={settingUp ? "setup" : "login"} submitLabel={settingUp ? "Create sign-in" : "Sign in"} autoFocus onDone={enterApp} />
      {!settingUp && (
        <p className="text-center text-12 text-fg-tertiary">
          Forgot it? Run <code className="font-mono">make signin</code> where Vesper runs for a one-time link.
        </p>
      )}
    </div>
  );
}
