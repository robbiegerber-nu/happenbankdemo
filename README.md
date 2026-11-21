# Happen Bank Contact Center — Demo Dataset

Interactive banking analytics using PostgreSQL, Python, and AI Assisted Development.

> **100% synthetic data.** Generated for dashboard demonstrations. This is **not** real Happen Bank data, and every agent, supervisor and customer is fictional. Product names are generic.

This repository builds a realistic contact center database: 34 months (Jan 2024 – Oct 2026) and 5.9 million contacts across phone, chat, email, callback and secure message. It includes agents, schedules and adherence, IVR, surveys, complaints, customers, personas and product launches. It is the foundation for a data health dashboard and a contact center analytics dashboard published with GitHub Pages.

## 📖 Documentation lives in the wiki

| | |
|---|---|
| **[Project wiki home](https://github.com/robbiegerber-nu/happenbankdemo/wiki)** | The step-by-step story of the project, phase by phase |
| **[Data Dictionary](https://github.com/robbiegerber-nu/happenbankdemo/wiki/Data-Dictionary)** | Data model, ER diagram, conventions, NULL meanings, table index |
| [Lookup Tables](https://github.com/robbiegerber-nu/happenbankdemo/wiki/Data-Dictionary-Lookup-Tables) · [Fact & Customer Tables](https://github.com/robbiegerber-nu/happenbankdemo/wiki/Data-Dictionary-Fact-Tables) | Every column with type, keys and description |
| [KPI Definitions](https://github.com/robbiegerber-nu/happenbankdemo/wiki/Data-Dictionary-KPI-Definitions) | Service level, ASA, AHT, adherence, occupancy, FCR, CSAT, NPS… |
| [Dashboard Views](https://github.com/robbiegerber-nu/happenbankdemo/wiki/Data-Dictionary-Views) | The ready-made `v_*` views for BI tools |
| [Building the Dataset](https://github.com/robbiegerber-nu/happenbankdemo/wiki/1-Building-the-Dataset) | How and why the data was generated, calibrated and validated |

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
| [`tools/`](tools/) | `generate_data_dictionary.ps1`: rebuilds the wiki's column pages from the database's own documentation |
| `docs/` | The GitHub Pages dashboards *(in progress)* |
