// Demo web app — the "hello" endpoint client.
const GREETINGS = ["hello", "hi"] as const;

type Greeting = { text: string };

export function greet(name: string): Greeting {
  return { text: `${GREETINGS[0]}, ${name}` }; // TODO: pick a random greeting
}

export const handlers = new Map<string, (n: string) => Greeting>([
  ["greet", greet],
]);
