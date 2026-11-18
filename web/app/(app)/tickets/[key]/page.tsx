import { Suspense, use } from "react";
import { TicketScreen } from "./ticket-screen";

function Loader({ params }: { params: PageProps<"/tickets/[key]">["params"] }) {
  const { key } = use(params);
  return <TicketScreen ticketKey={decodeURIComponent(key).toUpperCase()} />;
}

export default function TicketPage({ params }: PageProps<"/tickets/[key]">) {
  // params are request-time data under Cache Components, so they stream in Suspense.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
