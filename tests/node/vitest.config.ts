import { defineConfig } from "vitest/config";

// Cobertura is the report node.yml reads, for both coverage-min and
// diff-coverage; text is for the terminal.
export default defineConfig({
  test: {
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      reporter: ["text", "cobertura"],
    },
  },
});
