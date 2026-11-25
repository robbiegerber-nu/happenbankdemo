# Checking the chat's answers

Copies the question log and readers' reports to Postgres, works out each figure again from the source tables, and compares. Needs the Cloudflare sign-in and the `happen_demo` database.

```powershell
node chat/qa/sync_log.mjs
```

```powershell
node chat/qa/verify_log.mjs
```

Then, in pgAdmin:

| View | What it shows |
|---|---|
| `qa.v_chat_verdict` | One row per question: the verdict, and what a person still needs to look at |
| `qa.v_chat_check` | One row per figure requested: what differs, and the SQL |
| `qa.v_chat_log`, `qa.v_chat_call` | The questions, and the requests behind them |

The SQL for each question is also written to a text file, outside this project because it holds people's questions. The script prints the folder.

| Verdict | Meaning |
|---|---|
| **match** | Every comparison agrees with the source tables |
| **mismatch** | At least one differs. Start here |
| **no figure** | The chat gave no figure, or the page refused the request |
| **not covered** | A kind of request with no template yet |
| **not finished** | The page was closed before the answer |
| **error** | The check itself failed |

What is compared: values, how they are shown, record counts, "too few", status against target, changes and their chance readings, shares, the groups listed and their order, trend months, highest and lowest, and the filters and months used. For launches: contacts against expected, the peak, when it was back to normal, each change and its chance reading, and overlapping launches. For outcomes: both groups and whether the gap is beyond chance. For personas: every field of every profile.

Not compared: the events listed beside a result, which come from `events.json`, and fixed notes.

**A match means the figures the chat was given are right for what it asked for.** A person still has to judge whether it asked for the right thing and worded the answer fairly. Figures in the answer that weren't in the results are flagged separately (`unchecked`).

The SQL comes from fixed templates in [`verify.mjs`](verify.mjs) and never reads the `dash` tables behind the dashboards. It shares their rounding and target rules (`docs/assets/site.js`, `kpis.json`). Tests: `node chat/tests/verify.mjs`.

## Readers' reports

`sync_log.mjs` also copies reports (tickets). Review them with:

```powershell
node chat/qa/ticket.mjs
```

Add a number to see one (`node chat/qa/ticket.mjs 1`), then `--status` and `--finding` to record your decision. `--issue` **previews** a public GitHub issue; it is only created with `--publish`. `--close "..."` previews closing it. **Readers are told a response will be posted within 5 business days.** The list shows when each is due (holidays aren't skipped), and a ticket can't be closed without an issue unless you add `--no-response`. A ticket holds the whole conversation up to the reported answer. The response shows the questions the reader agreed to, the chat's answers to them and the comment. Earlier reports keep what they were promised. Text that looks like it holds an email, phone, ID or account number is held until you choose `--hide-question` or `--show-question`.

`private_tickets.mjs` puts the **full ticket** (reason, comment, question, answer, check, SQL, checklist) in a private repository, for whoever handles it, and deletes it after 90 days. It checks new answers first, and previews unless you add `--publish`, and stops unless GitHub says the repository is private. `ticket.mjs` notes the public response there.

**To respond, comment on the private ticket.** A comment that starts with `RESPOND no problem:` (or `problem confirmed`, `more information`, `duplicate`) is posted publicly; `RESPOND HIDE DETAILS no problem:` leaves the question and comment out; `CLOSE:` closes both; `CLOSE WITHOUT RESPONSE:` is for tests and spam. `respond.mjs` does it: it previews unless you add `--publish`, uses only approved people's comments, and refuses a response that repeats the reader's words. The `ticket.mjs` commands still work.

`daily_check.ps1` copies, checks, adds new tickets to the private repository, posts responses written there and shows a message when there is something to review. `-Install` runs it every day.

## Notes

If data was corrected after a question was asked, a difference may be the correction. The dates are in `qa.v_chat_check`.
