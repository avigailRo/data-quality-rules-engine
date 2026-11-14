/* 07 - Sample controls (stored as JSON AST, exactly like controls created in the UI) */
USE DataControls;
GO
SET NOCOUNT ON;

DECLARE @r TABLE (Id UNIQUEIDENTIFIER, Name NVARCHAR(200), Description NVARCHAR(1000), Severity NVARCHAR(20), Def NVARCHAR(MAX));

INSERT INTO @r VALUES
('11111111-0000-0000-0000-000000000001', N'קטין עם שכר גבוה', N'עובדים שגילם נמוך מ־18 ושכרם גבוה מ־15,000 ש"ח', N'High',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["age"]},"operator":"lt","right":{"kind":"value","value":18}},
   {"type":"comparison","id":"c2","left":{"kind":"field","path":["salary"]},"operator":"gt","right":{"kind":"value","value":15000}}]},
   "output":{"displayFields":["fullName","age","salary"]}}'),
('11111111-0000-0000-0000-000000000002', N'סיום העסקה לפני תחילתה', N'תאריך סיום העסקה מוקדם מתאריך תחילת העסקה', N'High',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["terminationDate"]},"operator":"lt","right":{"kind":"field","path":["hireDate"]}}]},
   "output":{"displayFields":["fullName","hireDate","terminationDate"]}}'),
('11111111-0000-0000-0000-000000000003', N'עובד פעיל במחלקה לא פעילה', N'עובדים פעילים המשויכים למחלקה שאינה פעילה', N'Medium',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["status"]},"operator":"eq","right":{"kind":"value","value":"A"}},
   {"type":"comparison","id":"c2","left":{"kind":"field","path":["department","isActive"]},"operator":"eq","right":{"kind":"value","value":false}}]},
   "output":{"displayFields":["fullName","department.name"]}}'),
('11111111-0000-0000-0000-000000000004', N'חסרים פרטי קשר', N'דוא"ל או טלפון חסרים, למרות שהם חובה לפי הכללים העסקיים', N'Low',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"or","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["email"]},"operator":"isEmpty"},
   {"type":"comparison","id":"c2","left":{"kind":"field","path":["phone"]},"operator":"isEmpty"}]},
   "output":{"displayFields":["fullName","email"]}}'),
('11111111-0000-0000-0000-000000000005', N'שיוך פרויקט לא תקין', N'לפחות שיוך אחד שמסתיים לפני שהתחיל, או שמתחיל לפני קליטת העובד', N'Medium',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"collection","id":"q1","relation":"projectAssignments","quantifier":"any","condition":
     {"type":"group","id":"g2","logic":"or","negate":false,"children":[
       {"type":"comparison","id":"c1","left":{"kind":"field","path":["endDate"]},"operator":"lt","right":{"kind":"field","path":["startDate"]}},
       {"type":"comparison","id":"c2","left":{"kind":"field","path":["startDate"]},"operator":"lt","right":{"kind":"field","scope":"root","path":["hireDate"]}}]}}]},
   "output":{"displayFields":["fullName","hireDate"]}}'),
('11111111-0000-0000-0000-000000000006', N'עובד פעיל ללא שיוך לפרויקט', N'עובדים פעילים שאין להם אף שיוך לפרויקט', N'Low',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["status"]},"operator":"eq","right":{"kind":"value","value":"A"}},
   {"type":"collection","id":"q1","relation":"projectAssignments","quantifier":"none"}]},
   "output":{"displayFields":["fullName","department.name"]}}'),
('11111111-0000-0000-0000-000000000007', N'שכר מעל טווח התפקיד', N'שכר העובד גבוה מהשכר המקסימלי שהוגדר לתפקיד שלו', N'Medium',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["salary"]},"operator":"gt","right":{"kind":"field","path":["position","maxSalary"]}}]},
   "output":{"displayFields":["fullName","position.title","salary"]}}');

DECLARE @now DATETIME2(0) = SYSUTCDATETIME();

INSERT INTO dq.[Rule] (Id, Name, Description, RootEntityKey, DefinitionJson, SchemaVersion, Status, Severity, Origin, CurrentVersion, CreatedBy, CreatedAt, UpdatedBy, UpdatedAt)
SELECT Id, Name, Description, N'employee', Def, 1, N'Active', Severity, N'Manual', 1, N'seed', @now, N'seed', @now FROM @r;

INSERT INTO dq.RuleVersion (RuleId, VersionNo, Name, DefinitionJson, CreatedBy, CreatedAt)
SELECT Id, 1, Name, Def, N'seed', @now FROM @r;
GO
