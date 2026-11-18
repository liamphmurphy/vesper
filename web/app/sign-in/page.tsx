import { Suspense, use } from "react";
import { SignInPanel } from "./sign-in-panel";

function Panel({ searchParams }: { searchParams: PageProps<"/sign-in">["searchParams"] }) {
  const { error } = use(searchParams);
  return <SignInPanel linkFailed={Boolean(error)} />;
}

/**
 * Where the app sends a browser the API refused. A fresh install is set up
 * here (the first browser picks the owner's username and password); after
 * that it takes the password, and `make signin` links stay the way back in.
 */
export default function SignInPage({ searchParams }: PageProps<"/sign-in">) {
  return (
    <main className="grid min-h-dvh place-items-center px-4">
      <Suspense>
        <Panel searchParams={searchParams} />
      </Suspense>
    </main>
  );
}
