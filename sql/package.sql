DROP TABLE IF EXISTS "package";
CREATE TABLE "package" ("id" INTEGER PRIMARY KEY  AUTOINCREMENT  NOT NULL , "name"  NOT NULL , "done" INTEGER NOT NULL  DEFAULT 0, "class" CHAR, "builder" CHAR, "start" DATETIME, "finish" DATETIME);
INSERT INTO "package" VALUES(1,'pkg a',0,NULL,NULL,NULL,NULL);
INSERT INTO "package" VALUES(2,'pkg b',0,NULL,NULL,NULL,NULL);
INSERT INTO "package" VALUES(3,'pkg c',0,NULL,NULL,NULL,NULL);
INSERT INTO "package" VALUES(4,'pkg z',1,NULL,NULL,NULL,NULL);