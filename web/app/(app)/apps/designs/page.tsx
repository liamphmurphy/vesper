import { redirect } from "next/navigation";

// Designs live in Knowledge now (LAZYAGENTS-212): New page makes one, the explorer lists them.
export default function Page() {
  redirect("/knowledge");
}
