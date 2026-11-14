import { redirect } from "next/navigation";

// Decks live in Knowledge now (LAZYAGENTS-212): New page makes one, the explorer lists them.
export default function Page() {
  redirect("/knowledge");
}
