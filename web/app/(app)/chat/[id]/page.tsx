import { Suspense, use } from "react";
import { ChatScreen } from "../_components/chat-screen";

function Loader({ params }: { params: PageProps<"/chat/[id]">["params"] }) {
  const { id } = use(params);
  return <ChatScreen id={decodeURIComponent(id)} />;
}

export default function Page({ params }: PageProps<"/chat/[id]">) {
  // params are request-time data under Cache Components, so they stream in Suspense.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
