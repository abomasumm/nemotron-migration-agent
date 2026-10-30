You are helping set up a code migration. Below are facts detected from the repository and the start of each
source file. Suggest answers the owner will confirm or edit. Read only what is below; do not use tools.

Reply with ONLY this JSON object, no prose:
{
  "to": "<most likely migration target, e.g. TypeScript (strict)>",
  "must_not_change": ["<one concrete, testable sentence each, naming the function and an example, e.g. formatMoney puts the minus sign before the symbol (-€12.30)>", "..."],
  "critical": ["<module path whose breakage would hurt most>", "..."],
  "approach": ["<how to sequence it: e.g. convert framework-independent modules first, then switch the framework for the app, server and routes together in one task; which public boundary (exported function, HTTP contract) must stay identical>", "..."],
  "notes": ["<one-line migration risk or quirk you noticed in the code, e.g. float rounding, implicit any, mutation of arguments>", "..."]
}
Keep each list to at most 6 items. Name real functions and files from the code. must_not_change items are
behaviour a test can check (inputs and the exact outputs or errors), never just a function name. No semicolons
inside items.
