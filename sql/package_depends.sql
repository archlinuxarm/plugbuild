DROP TABLE IF EXISTS "package_depends";
CREATE TABLE "package_depends" ("id" INTEGER PRIMARY KEY  NOT NULL ,"package" INTEGER NOT NULL ,"dependancy" INTEGER NOT NULL );
INSERT INTO "package_depends" VALUES(1,1,2);
INSERT INTO "package_depends" VALUES(2,1,3);
INSERT INTO "package_depends" VALUES(3,2,3);
INSERT INTO "package_depends" VALUES(4,3,4);
