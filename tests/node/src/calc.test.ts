import { describe, expect, it } from "vitest";

import { add, divide } from "./calc.js";

describe("calc", () => {
  it("adds", () => {
    expect(add(2, 3)).toBe(5);
  });

  it("divides", () => {
    expect(divide(6, 3)).toBe(2);
  });

  it("refuses to divide by zero", () => {
    expect(() => divide(1, 0)).toThrow(RangeError);
  });
});
