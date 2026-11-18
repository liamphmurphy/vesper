import { Providers } from "./providers";
import "../styles/fonts.css";
import "./globals.css";
import "../styles/native-mac.css";

// <html>, <head> (title, viewport, theme-color, the pre-paint appearance script) and <body> live in
// index.html; fonts are self-hosted in styles/fonts.css.
export default function RootLayout({ children }: LayoutProps<"/">) {
  return <Providers>{children}</Providers>;
}
