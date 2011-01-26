select
    p.id,p.name,
    count(dp.id),
    sum(d.done)
from
    package as p
    inner join package_depends as dp on ( p.id = dp.package)
    left outer join package as d on (d.id = dp.dependancy)
group by p.id
having count(dp.id) == sum(d.done);