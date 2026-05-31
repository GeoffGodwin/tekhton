# max-turns-coder

Coder agent exhausted CODER_MAX_TURNS on consecutive attempts.
Inputs: LAST_FAILURE_CONTEXT.json carries category=AGENT_SCOPE / subcategory=max_turns
(or, M129-schema-v2 form, the secondary cause object).

Expected bash verdict:
  classification = MAX_TURNS_EXHAUSTED
  confidence     = high
  rule           = _rule_max_turns
  stage          = coder
