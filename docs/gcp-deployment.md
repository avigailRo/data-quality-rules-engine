# מיפוי לפריסה ב־GCP (תכנון, לא מומש)

| רכיב מקומי | ב־GCP | הערות |
| --- | --- | --- |
| ‏ASP.NET Core API | Cloud Run | Stateless. ‏Health checks ב־`/health/live` וב־`/health/ready`. |
| ‏dq-advisor (Python) | Cloud Run (Ingress פנימי בלבד) | קריאות Service-to-Service עם ID Token במקום `X-Service-Token`. |
| ‏Angular | Cloud Storage + Cloud CDN, או Firebase Hosting | ‏Build סטטי. |
| ‏SQL Server | Cloud SQL for SQL Server | ‏Logins נפרדים: `dc_app`, ‏`dc_rule_reader` ו־`dc_profiler`. |
| ‏LLM | Vertex AI (Gemini) | ‏`DQ_LLM_PROVIDER=vertex`. הרשאה באמצעות Service Account עם `roles/aiplatform.user`. |
| סודות | Secret Manager | Connection strings ו־Tokens. |
| לוגים | Cloud Logging | ה־API וה־Python כותבים לוגים בפורמט JSON. |
| תור הרצות | Cloud Tasks או Pub/Sub | מחליף את `ChannelRunQueue` דרך הממשק `IRunQueue`. |
| תזמון | Cloud Scheduler | הרצה תקופתית של בקרות פעילות. |
| אימות משתמשים | Identity Platform או IAP | מחליף את `DevAuthHandler`. |
