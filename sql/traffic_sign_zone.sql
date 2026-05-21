-- Derive traffic sign locations and directions from traffic sign centerline tags
-- for zones: Extract zone "entrances" and place a single traffic sign node at each zone entrance
-------------------------------------------------------------------------------------------------

BEGIN; -- Using BEGIN-END-transaction for autodeleting temporary tables at the end


-- 1) Merge segments for zones by same traffic sign id's
CREATE TEMP TABLE segments AS
WITH zone_ids AS (
    SELECT unnest(ARRAY['242', '250', '251', '253', '260', '270', '274.1', '290', '314', '325']) AS sign_id
)
SELECT 
    z.osm_type,
    z.osm_id,
    z.country_code,
    z.sign_list,
    z.main_signs,
    z.highway,
    z.layer,
    ST_LineMerge(ST_UnaryUnion(ST_Collect(z.geom))) AS geom
FROM zone_ids
JOIN traffic_sign_zone z
    ON z.sign_list LIKE '%' || zone_ids.sign_id || '%'
GROUP BY z.osm_type, z.osm_id, z.country_code, z.sign_list, z.main_signs, z.highway, z.layer;

CREATE INDEX segments_geom_idx ON segments USING GIST (geom);


-- 2) Determine zone entrance nodes by counting vertices on exploded highway segments
-- (at zone entrances, roads with zone traffic signs are meeting with other road segments without zone traffic signs)
CREATE TEMP TABLE entrance AS
WITH exploded_lines AS (
    SELECT DISTINCT
        segments.osm_type,
        segments.osm_id,
        segments.country_code,
        segments.sign_list,
        segments.main_signs,
        segments.highway,
        segments.layer,
        CASE
            WHEN highway.traffic_sign LIKE '%' || segments.sign_list || '%'
            THEN 'road'
            ELSE 'connected_road'
        END AS highway_type,
        (ST_DumpSegments(highway.geom)).geom AS geom
    FROM highway
    JOIN segments
    ON ST_Intersects(highway.geom, segments.geom)
    WHERE
        segments.highway IN ('primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'residential', 'living_street', 'pedestrian', 'road')
        AND highway.highway IN ('primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'residential', 'living_street', 'pedestrian', 'road')
),

-- Extract vertices
vertices AS (
    SELECT
        osm_type,
        osm_id,
        country_code,
        sign_list,
        main_signs,
        highway,
        layer,
        highway_type,
        (ST_DumpPoints(geom)).geom AS geom
    FROM exploded_lines
),

-- Count vertices
vertex_count AS (
    SELECT
        geom,
        osm_type,
        osm_id,
        country_code,
        sign_list,
        main_signs,
        highway,
        layer,
        -- Number of roads that are meeting at this point
        COUNT(*) AS vertex_count,
        -- Number of connected roads (without zone traffic signs) that are meeting at this point
        COUNT(CASE WHEN highway_type = 'connected_road' THEN 1 END) AS vertex_count_connected_road
    FROM vertices
    GROUP BY geom, osm_type, osm_id, country_code, sign_list, main_signs, highway, layer
)

-- Extract zone entrance points
SELECT DISTINCT
    geom,
    row_number() OVER () AS id,
    osm_type,
    osm_id,
    country_code,
    sign_list,
    main_signs,
    highway,
    layer
FROM vertex_count
WHERE
    vertex_count > vertex_count_connected_road
    AND vertex_count_connected_road > 0;


-- 3) Buffer zone entrance points
CREATE TEMP TABLE entrance_buffers AS
SELECT DISTINCT
    ST_Buffer(geom, 8) AS geom,
    id,
    osm_type,
    osm_id,
    country_code,
    sign_list,
    main_signs,
    highway,
    layer
FROM entrance;

CREATE INDEX entrance_buffers_geom_idx ON entrance_buffers USING GIST (geom);


-- 4) Create traffic sign nodes where buffer circle and zone segments are intersecting
DROP TABLE IF EXISTS traffic_sign_nodes_zone;

CREATE TABLE traffic_sign_nodes_zone AS

WITH buffer_boundaries AS (
    SELECT
        id,
        osm_type,
        osm_id,
        country_code,
        sign_list,
        main_signs,
        highway,
        layer,
        ST_Boundary(geom) AS geom
    FROM entrance_buffers
),

buffer_intersections AS (
    SELECT
        b.id,
        b.osm_type,
        b.osm_id,
        b.country_code,
        b.sign_list,
        b.main_signs,
        b.highway,
        b.layer,
        ST_Intersection(b.geom, segments.geom) AS geom
    FROM buffer_boundaries b
    JOIN segments
        ON b.sign_list = segments.sign_list
    WHERE ST_Intersects(b.geom, segments.geom)
)

SELECT
    buffer_intersections.osm_type,
    buffer_intersections.osm_id,
    buffer_intersections.country_code,
    buffer_intersections.sign_list,
    buffer_intersections.main_signs,
    DEGREES(ST_Azimuth(ST_GeometryN(buffer_intersections.geom, 1), ST_GeometryN(entrance.geom, 1)))::INT AS direction,
    buffer_intersections.highway,
    buffer_intersections.layer,
    (ST_Dump(buffer_intersections.geom)).geom AS geom
FROM buffer_intersections, entrance
WHERE entrance.id = buffer_intersections.id;

CREATE INDEX traffic_sign_nodes_zone_geom_idx ON traffic_sign_nodes_zone USING GIST (geom);

-- TODO: place a "ending" traffic sign id (like DE:244.2) when exiting a zone
-- (only possible if traffic signs are placed beside the centerlines to have an "starting" sign when entering and a "ending" sign when leaving the zone)

END; -- delete temporary tables