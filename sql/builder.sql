DROP TABLE IF EXISTS "package";
CREATE TABLE "package" ("id" INTEGER PRIMARY KEY  AUTOINCREMENT  NOT NULL , "name"  NOT NULL , "done" INTEGER NOT NULL  DEFAULT 0, "class" CHAR, "builder" CHAR, "start" DATETIME, "finish" DATETIME);
INSERT INTO "package" VALUES(1,'pkg a',0,NULL,NULL,NULL,NULL);
INSERT INTO "package" VALUES(2,'pkg b',0,NULL,NULL,NULL,NULL);
INSERT INTO "package" VALUES(3,'pkg c',0,NULL,NULL,NULL,NULL);
INSERT INTO "package" VALUES(4,'pkg z',1,NULL,NULL,NULL,NULL);

DROP TABLE IF EXISTS "package_depends";
CREATE TABLE "package_depends" ("id" INTEGER PRIMARY KEY  NOT NULL ,"package" INTEGER NOT NULL ,"dependancy" INTEGER NOT NULL );


DROP TABLE IF EXISTS "package_name_provides";
CREATE TABLE "package_name_provides" ("id" INTEGER PRIMARY KEY  NOT NULL ,"name" CHAR,"provides" INTEGER,"package" INTEGER);
INSERT INTO "package_name_provides" VALUES(1,'d',0,1);
INSERT INTO "package_name_provides" VALUES(2,'e',0,1);
INSERT INTO "package_name_provides" VALUES(3,'f',0,1);
INSERT INTO "package_name_provides" VALUES(4,'g',1,2);
INSERT INTO "package_name_provides" VALUES(5,'h',1,2);
INSERT INTO "package_name_provides" VALUES(6,'i',0,2);
INSERT INTO "package_name_provides" VALUES(7,'j',1,3);
INSERT INTO "package_name_provides" VALUES(8,'k',0,3);
INSERT INTO "package_name_provides" VALUES(9,'l',1,4);



insert into package_depends (dependancy,package) select distinct(package), 1 from package_name_provides where name in ('g','h','k');
insert into package_depends (dependancy,package) select distinct(package), 2 from package_name_provides where name in ('k','l');
insert into package_depends (dependancy,package) select distinct(package), 3 from package_name_provides where name in ('l');


select
    p.id,p.name,
    count(dp.id),
    sum(d.done)
from
    package as p
    inner join package_depends as dp on ( p.id = dp.package)
    left outer join package as d on (d.id = dp.dependancy)
group by p.id
having count(dp.id) == sum(d.done) and p.done <> 1;

