# Happen Bank Contact Center — Demo Dataset

Interactive banking analytics using PostgreSQL, Python, and AI Assisted Development.

> **100% synthetic data.** Generated for dashboard demonstrations. This is **not** real Happen Bank data, and every agent, supervisor and customer is fictional. Product names are generic.

This repository builds a realistic contact center database: 34 months (Jan 2024 – Oct 2026), 5.9 million contacts and 15 daily loads for November 2026, across phone, chat, email, callback and secure message. It includes agents, schedules and adherence, IVR, surveys, complaints, customers, personas and product launches. It feeds the dashboards below, published with GitHub Pages.

## Dashboards

**[Open the dashboards home page](https://robbiegerber-nu.github.io/happenbankdemo/)**, or go straight to one:

| Dashboard | Question it answers |
|---|---|
| [Executive scorecard](https://robbiegerber-nu.github.io/happenbankdemo/executive.html) | Are we meeting our targets? |
| [Service & access operations](https://robbiegerber-nu.github.io/happenbankdemo/service.html) | When and where do customers wait? |
| [Workforce management](https://robbiegerber-nu.github.io/happenbankdemo/workforce.html) | Do we have the right people at the right time? |
| [Agent & team coaching](https://robbiegerber-nu.github.io/happenbankdemo/coaching.html) | Who could use coaching, on what, and is it a real gap? |
| [Customer experience](https://robbiegerber-nu.github.io/happenbankdemo/cx.html) | How do customers feel, and what drives it? |
| [Product launch impact](https://robbiegerber-nu.github.io/happenbankdemo/launch.html) | What happens after a launch, and for how long? |
| [Customer & persona insights](https://robbiegerber-nu.github.io/happenbankdemo/personas.html) | Who contacts us most, how, and who has the worst experience? |
| [Self-service & channel shift](https://robbiegerber-nu.github.io/happenbankdemo/selfservice.html) | Are phone menus and digital channels absorbing demand? |
| [Performance driver explorer](https://robbiegerber-nu.github.io/happenbankdemo/drivers.html) | What changed, and what drove it? |
| [Process stability monitor](https://robbiegerber-nu.github.io/happenbankdemo/stability.html) | Is this a real change or normal variation? |
| [Data quality](https://robbiegerber-nu.github.io/happenbankdemo/quality.html) | Can we trust the data? |
| [Ask the data](https://robbiegerber-nu.github.io/happenbankdemo/chat.html) (AI chat) | Can I ask in my own words? Prepared questions for everyone, open questions with an access code |

## 📖 Documentation lives in the wiki

| | |
|---|---|
| **[Project wiki home](https://github.com/robbiegerber-nu/happenbankdemo/wiki)** | The step-by-step story of the project, phase by phase |
| **[Data Dictionary](https://github.com/robbiegerber-nu/happenbankdemo/wiki/Data-Dictionary)** | Data model, ER diagram, conventions, NULL meanings, table index |
| [Lookup Tables](https://github.com/robbiegerber-nu/happenbankdemo/wiki/Data-Dictionary-Lookup-Tables) · [Fact & Customer Tables](https://github.com/robbiegerber-nu/happenbankdemo/wiki/Data-Dictionary-Fact-Tables) | Every column with type, keys and description |
| [KPI Definitions](https://github.com/robbiegerber-nu/happenbankdemo/wiki/Data-Dictionary-KPI-Definitions) | Service level, ASA, AHT, adherence, occupancy, FCR, CSAT, NPS… |
| [Dashboard Views](https://github.com/robbiegerber-nu/happenbankdemo/wiki/Data-Dictionary-Views) | The ready-made `v_*` views for BI tools |
| [Building the Dataset](https://github.com/robbiegerber-nu/happenbankdemo/wiki/1a-Building-the-Dataset) | How and why the data was generated, calibrated and validated |

## Quick start

Requires PostgreSQL 18 on `localhost:5432`, with the password for user `postgres` in `%APPDATA%\postgresql\pgpass.conf`.

```powershell
powershell -File sql\run_all.ps1
```

This takes about 75 minutes. It drops and recreates the `happen_demo` database, then runs 24 validation checks. Connect any SQL or BI tool to database `happen_demo`, schema `cc`, and start from the `cc.v_*` views.

## Repository layout

| Path | Contents |
|---|---|
| [`sql/`](sql/) | Numbered scripts that build the database (`00`–`12`), the validation suite (`99_validate.sql`) and `run_all.ps1` |
| [`sql/discovery/`](sql/discovery/) | Data discovery & data quality toolkit: column profiling, 101 rules stored as data, run history, JSON export ([how it works](https://github.com/robbiegerber-nu/happenbankdemo/wiki/2a-Data-Discovery)) |
| [`sql/pipeline/`](sql/pipeline/) | Daily loads: feed generation, loading, incidents, alerts and reset ([how it works](https://github.com/robbiegerber-nu/happenbankdemo/wiki/2b-Data-Quality-Pipeline)) |
| [`sql/dashboards/`](sql/dashboards/) | Exports the JSON the operational dashboards read, refreshed after each daily load with no failed check |
| [`sql/remediation/`](sql/remediation/) | Documented, re-runnable fixes for data defects found by discovery |
| [`tools/`](tools/) | `generate_data_dictionary.ps1`: rebuilds the wiki's column pages from the database's own documentation |
| [`chat/`](chat/) | The AI chat's server, tests and question log for quality checks ([how it works](https://github.com/robbiegerber-nu/happenbankdemo/wiki/3c-AI-Chat)) |
| [`docs/`](docs/) | GitHub Pages site: the dashboards above and their JSON data |
