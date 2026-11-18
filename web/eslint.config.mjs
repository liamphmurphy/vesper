import { defineConfig, globalIgnores } from "eslint/config";
import reactHooks from "eslint-plugin-react-hooks";
import tseslint from "typescript-eslint";

const eslintConfig = defineConfig([
  ...tseslint.configs.recommended,
  reactHooks.configs.flat.recommended,
  {
    // What eslint-config-next's TypeScript preset reported as warnings.
    rules: { "@typescript-eslint/no-unused-vars": "warn", "@typescript-eslint/no-unused-expressions": "warn" },
  },
  globalIgnores(["dist/**", "node_modules/**", "test-results/**", "playwright-report/**"]),
]);

export default eslintConfig;
