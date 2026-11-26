// A deliberately tiny module: enough code for node.yml's self-test to type
// check, lint, format-check and measure, and nothing else.

export function add(a: number, b: number): number {
  return a + b;
}

export function divide(a: number, b: number): number {
  if (b === 0) {
    throw new RangeError("division by zero");
  }
  return a / b;
}
