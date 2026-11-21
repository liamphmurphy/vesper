```go
package main

import "fmt"

// main prints a greeting.
func main() {
	count := 3
	fmt.Println("hello", count)
}
```

```ts
interface Ticket { key: string; points?: number }
export const total = (ts: Ticket[]): number => ts.reduce((n, t) => n + (t.points ?? 0), 0);
```

```python
def fib(n: int) -> int:
    """Return the nth Fibonacci number."""
    return n if n < 2 else fib(n - 1) + fib(n - 2)
```

```json
{ "name": "vesper", "private": true, "count": 2, "tags": ["a", null] }
```

```bash
#!/usr/bin/env bash
echo "$HOME" && ls -la | grep -v '^d'
```

```unknownlang
plain text, not highlighted
```

~~~
tilde fence without a language
~~~

Display math:

$$
E = mc^2
$$

Inline math $$a_1 + b_2$$ in a sentence, and a price of $5.
