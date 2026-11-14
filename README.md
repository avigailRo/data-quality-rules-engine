# מערכת בקרות נתונים דינאמית

מערכת Web גנרית שבה משתמשים עסקיים מגדירים בקרות איכות נתונים, מריצים אותן ורואים את הרשומות החריגות ואת סיבת החריגה. אין צורך לכתוב SQL ואין צורך לשנות קוד כדי להוסיף בקרה.

**טכנולוגיות:** ASP.NET Core 10 (Minimal APIs), Angular 21 (Standalone, Signals, Reactive Forms, Zoneless), Python 3.12 (FastAPI), SQL Server.

## הרצה מקומית (Windows)

דרישות: SQL Server (מוגדר כברירת מחדל ל־`.\SQLEXPRESS` עם Windows Authentication), ‎.NET SDK 10, Node.js 20.19 ומעלה, Python 3.12 ו־ODBC Driver 17 או 18 for SQL Server.

### 1. בסיס הנתונים

```powershell
powershell -ExecutionPolicy Bypass -File .\db\reset.ps1
```

אם `sqlcmd` אינו מותקן: פתחו את `db\setup_all.sql` ב־SSMS, התחברו ל־`.\SQLEXPRESS` והריצו (F5).
הסקריפט מוחק את מסד הדמו ומקים אותו מחדש, כך שאפשר להריץ אותו שוב בכל שלב.

### 2. ה־API (‎.NET)

```powershell
cd backend
dotnet run --project src/DataControls.Api      # http://localhost:5080
dotnet test                                   # בדיקות יחידה למנוע
```

שרת אחר: שנו את `Database:ConnectionString` בקובץ `backend/src/DataControls.Api/appsettings.json`.

### 3. שירות ההמלצות (Python)

```powershell
cd ai-service
python -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
uvicorn app.main:app --port 8000
python -m pytest
```

#### מנוע ההמלצות: מה פעיל ומה דורש הגדרה

| Provider | מה זה | סטטוס |
| --- | --- | --- |
| `heuristic` (ברירת מחדל) | ניתוח מקומי מבוסס Metadata וסטטיסטיקה, ללא LLM. מוצג בממשק כ"ניתוח מקומי". | פעיל ומאומת |
| `openai` | כל API תואם OpenAI: ‏Gemini (דרך ה־Endpoint התואם של Google), ‏OpenAI, ‏Azure OpenAI, או Ollama/LM Studio מקומי | מומש ונבדק מול Mock. מול Gemini בפועל (ראו למטה): המפתח מאומת, אבל בקשות ההמלצה לא הסתיימו מהרשת שבה פותח הפרויקט, ולכן לא הוכחה המלצה של LLM מקצה לקצה |
| `vertex` | ‏Gemini ב־Vertex AI (GCP) | מוכן; לא נבדק מול השירות |

הפעלה באמצעות Configuration בלבד (משתני סביבה, ללא סודות בקוד):

**בדיקה חיה מקצה לקצה (Gemini, מפתח חינמי מ־Google AI Studio):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\qa\run-llm-e2e.ps1
```

הסקריפט מבקש את המפתח בקלט מוסתר. המפתח נשמר רק בזיכרון התהליך, לא נכתב לדיסק, לא מועבר בשורת פקודה ולא נכתב ללוג.
הוא בודק: Metadata ← LLM ← המלצה ← ולידציה ב־Python וב־.NET ← אישור אנושי ← בקרה שמורה (Draft) ← הרצה על SQL Server, ואז מפתח שגוי ← Fallback מקומי.
התוצאות נכתבות ל־`qa/llm-e2e-log.txt`, כולל ההגדרה שהמודל החזיר.

**מה נבדק בפועל מול Gemini (14.11.2026, בסביבת פיתוח עם TLS Inspection):**

| בדיקה | תוצאה |
| --- | --- |
| המפתח מאומת ורשימת המודלים מתקבלת | עבר |
| אימות TLS ברשת עם TLS Inspection (שרשרת התעודות מ־Windows, ללא כיבוי אימות) | עבר |
| מפתח שגוי: ‏Gemini מחזיר HTTP 400, המערכת עוברת לניתוח המקומי ומסמנת את ההצעות כ"ניתוח מקומי" | עבר |
| אין שמירה של בקרה לפני אישור אנושי | עבר |
| המלצה של Gemini עם מפתח תקין | **לא הושלמה:** ‏HTTP 503 (המודל עמוס) ואחר כך Timeout, גם לבקשה זעירה של שורה אחת (`qa/gemini-probe.ps1`). לא אומת אם המקור הוא עומס אצל Google או מגבלה של הרשת המקומית |

בעקבות זה נוספו: ניסיון חוזר על 429/5xx, מעבר למודל חלופי (`DQ_LLM_FALLBACK_MODELS`), ותקציב זמן כולל לקריאה, כך שהניתוח המקומי עונה תמיד לפני ה־Timeout של ה־API.

הגדרה ידנית:

```powershell
# Gemini (חיצוני: סטטיסטיקות של שדות רגישים לא נשלחות)
$env:DQ_LLM_PROVIDER="openai"; $env:DQ_LLM_BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai"
$env:DQ_LLM_MODEL="gemini-flash-latest"; $env:DQ_LLM_REASONING_EFFORT="low"; $env:DQ_LLM_API_KEY=(Read-Host)
# LLM מקומי (הנתונים לא יוצאים מהמחשב), דורש Ollama ומודל מותקן
$env:DQ_LLM_PROVIDER="openai"; $env:DQ_LLM_BASE_URL="http://localhost:11434/v1"; $env:DQ_LLM_MODEL="qwen2.5:7b"
# OpenAI: בנוסף $env:DQ_LLM_API_KEY="..."  (לעולם לא בקוד)
uvicorn app.main:app --port 8000
```

אם ה־LLM לא זמין, מחזיר תשובה לא תקינה או חורג מהזמן (`DQ_LLM_TIMEOUT_SECONDS`), השירות עובר לניתוח המקומי ומציין זאת בממשק.
גם כשהשירות כבוי המערכת פועלת. רק מסך ההמלצות מציג הודעה שהשירות אינו זמין.

### 4. הממשק (Angular)

```powershell
cd frontend
npm install
npm start                                     # http://localhost:4200
```

בראש המסך יש בורר משתמשי דמו: **כותב בקרות** (ברירת מחדל), **צופה** (קריאה בלבד) ו**מנהל מערכת** (גם אימות קטלוג וצפייה ב־SQL).

## בדיקות

בדיקה מלאה אחת מריצה את כל השכבות: בסיס נתונים, build ו־18 בדיקות יחידה ב־.NET, אינטגרציה מול ה־API עם השוואה ל־SQL כתוב ידנית, ניסיונות תקיפה, 21 בדיקות Python, המלצות AI ו־build של Angular. בסוף היא מנקה את נתוני הבדיקה שיצרה.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\qa\run-qa.ps1
```

ב־Windows אפשר גם ללחוץ לחיצה כפולה על `qa\1-run-qa.cmd`. התוצאות נשמרות ב־`qa/qa-log.txt`.

## בקרות לדוגמה (נטענות מראש) והתוצאות הצפויות

| בקרה | מה היא מדגימה | עובדים חריגים |
| --- | --- | --- |
| קטין עם שכר גבוה | AND, שדה מחושב (גיל) | 21, 42 |
| סיום העסקה לפני תחילתה | השוואת שדה לשדה, NULL | 30, 45 |
| עובד פעיל במחלקה לא פעילה | תנאי על ישות קשורה (Many-to-One) | 7, 19, 33 |
| חסרים פרטי קשר | OR, ריק = NULL או מחרוזת ריקה | 12, 56, 77, 99 |
| שיוך פרויקט לא תקין | One-to-Many עם EXISTS, הפניה לרשומה הראשית | 15, 25, 150 (עובד 150 מופיע פעם אחת למרות 3 שיוכים שגויים) |
| עובד פעיל ללא שיוך לפרויקט | NOT EXISTS | 170, 171 |
| שכר מעל טווח התפקיד | השוואת שדה לשדה בין ישויות | 50, 51 |

מקרי ביקורת שאסור שיופיעו בתוצאות: עובד 63 (בן 17 עם שכר של 15,000 בדיוק), עובד 84 (קטין עם שכר נמוך), עובד 90 (מחלקה לא פעילה אבל העובד סיים לעבוד), עובד 111 (ללא מחלקה).

## מבנה הפרויקט

```text
db/            סקריפטי הקמה ונתוני דמו (01-07), reset.ps1, setup_all.sql
backend/       Domain (AST, Binder, Validator, הסברים) · Application (Use cases) · Infrastructure (SQL Compiler, Executor, Dapper) · Api
ai-service/    FastAPI: Profiler בטוח, מנוע כללים, Providers ל־LLM, ולידציה
frontend/      Angular: רשימת בקרות, בונה תנאים רקורסיבי, תוצאות, המלצות AI, קטלוג
docs/          ארכיטקטורה, הנחות ומגבלות, כלי AI שבהם השתמשתי, פריסה ל־GCP
```

מסמכים נוספים:

- [ארכיטקטורה ומנגנון הבקרות](docs/architecture.md)
- [הנחות, מגבלות והרחבות](docs/assumptions-limitations.md)
- [כלי AI שבהם נעשה שימוש](docs/ai-tools-used.md)
- [מיפוי לפריסה ב־GCP](docs/gcp-deployment.md)
- [החלטות תכנון: חלופות, אבטחה, AI, Roadmap](docs/design-decisions.md)
- [דוח ביקורת ו־QA סופי (82 בדיקות עברו, 0 נכשלו)](docs/final-audit.md)
