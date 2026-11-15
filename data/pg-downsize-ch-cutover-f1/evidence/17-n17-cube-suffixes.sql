-- olap.cube_suffixes: the live writer-side registry of which physical generation each cube
-- serves from, and (if the columns exist) whether fastlane has yielded the family to V4.
\d cube_suffixes
select * from cube_suffixes order by cube_name;
