# Validation queries

Queries for checking dashboard numbers against the database. They read the source tables in `cc` (and `discovery` for Data quality), not the `dash` tables the dashboard exports are built from, so they check the export as well as the page. Every query only reads data.

| File | Dashboard | Queries |
|---|---|---|
| [V01](V01_executive_scorecard.txt) | Executive scorecard | 5 |
| [V02](V02_service_access.txt) | Service & access operations | 5 |
| [V03](V03_workforce.txt) | Workforce management | 5 |
| [V04](V04_coaching.txt) | Agent & team coaching | 5 |
| [V05](V05_customer_experience.txt) | Customer experience | 4 |
| [V06](V06_launch_impact.txt) | Product launch impact | 5 |
| [V07](V07_personas.txt) | Customer & persona insights | 4 |
| [V08](V08_self_service.txt) | Self-service & channel shift | 5 |
| [V09](V09_driver_explorer.txt) | Performance driver explorer | 4 |
| [V10](V10_process_stability.txt) | Process stability monitor | 4 |
| [V11](V11_data_quality.txt) | Data quality | 5 |

Ask the data (the AI chat) has no file of its own: it answers with the other dashboards' calculations.

## How to use one

1. In pgAdmin 4, open the Query Tool on database `happen_demo`, and open a text file here in any editor.
2. Change the values in the block marked `CHANGE THESE VALUES`. Dates are included at both ends.
3. Copy that one query (from `WITH settings` to the `;`) into the Query Tool and run it. Compare with the page; the comment above each query says where to look.

```sql
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,
    DATE '2026-10-31'              AS end_date,
    'Phone | Chat'::text           AS channel,   -- 'All' = no filter; ' | ' between several values
    'All'::text                    AS queue
)
```

Names must match exactly. This lists the less obvious ones:

```sql
SELECT 'queue' AS filter, queue_name AS value FROM cc.dim_queue
UNION ALL SELECT 'reason', reason FROM cc.dim_contact_reason
UNION ALL SELECT 'team', team_name FROM cc.dim_team
UNION ALL SELECT 'persona', persona_name FROM cc.dim_persona
UNION ALL SELECT DISTINCT 'segment', segment FROM cc.customer
UNION ALL SELECT DISTINCT 'age_band', age_band FROM cc.customer
ORDER BY 1, 2;
```

## If a number differs

- **Dates.** Most pages show whole months or quarters; Service and Workforce show the 30 days to the last day of data. Contacts count on the day offered, surveys on the day answered, complaints on the day opened.
- **Data loaded since the export.** The pages show the last export. The footer gives its date.
- **Unidentified customers.** A persona, segment or age filter leaves out contacts with no customer.
- **Rounding.** Queries round like the page. Durations are in seconds, while the page shows minutes and seconds.

The expected values in the comments were compared with the pages on Nov 24, 2026 (data through Nov 15, 2026). Most queries take under 3 seconds; a few take up to about 20.
