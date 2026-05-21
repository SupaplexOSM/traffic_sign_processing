-- Derive traffic sign locations and directions from traffic sign centerline tags
-- for regular traffic signs (without zone signs): Extract intersections and place traffic sign nodes repeating et each intersection
------------------------------------------------------------------------------------------------------------------------------------

BEGIN; -- Using BEGIN-END-transaction for autodeleting temporary tables at the end


-- 1) Merge highway segments with traffic sign tags with same attributes
CREATE TEMP TABLE merged_ways AS
SELECT
    country_code, main_signs, sign_list, highway,
    CASE 
        WHEN highway IN ('primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'residential', 'living_street', 'pedestrian', 'road')
        THEN 'road'
        ELSE 'way'
    END AS highway_type,
    oneway, "oneway:bicycle",
    ST_LineMerge(ST_UnaryUnion(ST_Collect(geom))) AS geom
FROM traffic_sign_way
GROUP BY country_code, main_signs, sign_list, highway, oneway, "oneway:bicycle";

CREATE INDEX merged_ways_geom_idx ON merged_ways USING GIST (geom);


-- 2) Create buffers around way intersections (to place traffic sign nodes at the buffer edge later)
CREATE TEMP TABLE intersection_buffers AS

-- Create exploded highway segments for determining intersections by counting vertices
WITH exploded_lines AS (
    SELECT DISTINCT
        CASE
            WHEN highway.traffic_sign IS NULL
            THEN
                CASE
                    WHEN highway.highway IN ('primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'residential', 'living_street', 'pedestrian', 'road')
                    THEN 'connected_road'
                    ELSE 'connected_way'
                END
            ELSE
                CASE
                    WHEN highway.highway IN ('primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'residential', 'living_street', 'pedestrian', 'road')
                    THEN 'road'
                    ELSE 'way'
                END
        END AS highway_type,
        (ST_DumpSegments(highway.geom)).geom AS geom
    FROM highway
    JOIN traffic_sign_way
    ON ST_Intersects(highway.geom, traffic_sign_way.geom)
),

-- Extract vertices
vertices AS (
    SELECT
        highway_type,
        (ST_DumpPoints(geom)).geom AS geom
    FROM exploded_lines
),

-- Count vertices
vertex_count AS (
    SELECT
        geom,
        -- Number of roads and ways that are meeting at this point (indicator for way-way and way-road intersections)
        COUNT(*) AS vertex_count,
        -- Number of roads that are meeting at this point (indicator for road-road intersections)
        COUNT(CASE WHEN highway_type IN ('road', 'connected_road') THEN 1 END) AS vertex_count_road,
        -- Number of roads with traffic_sign tag that are meeting at this point (indicator for entrances and ends of traffic sign segments, esp. traffic signs zones)
        COUNT(CASE WHEN highway_type = 'road' THEN 1 END) AS vertex_count_ts_road
    FROM vertices
    GROUP BY geom
),

-- Extract intersection points (at intersections, at least 3 vertices have to be present for at least 3 meeting line segments)
intersections AS (
    -- road intersections
    SELECT
        geom,
        'road' AS intersection_type
    FROM vertex_count
    WHERE vertex_count_road >= 3
    UNION
    -- way intersections with roads
    SELECT
        vertex_count.geom,
        'way' AS intersection_type
    FROM vertex_count
    JOIN traffic_sign_way
    ON ST_Intersects(vertex_count.geom, traffic_sign_way.geom)
    WHERE
        vertex_count.vertex_count_road > 0
        AND vertex_count.vertex_count_road < 3
        AND vertex_count.vertex_count > vertex_count.vertex_count_road
        AND traffic_sign_way.highway NOT IN ('primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'residential', 'living_street', 'pedestrian', 'road')
)

-- Buffer intersection points
SELECT
    ST_Buffer(geom, 8) AS geom,
    intersection_type
FROM intersections;

CREATE INDEX intersection_buffers_geom_idx ON intersection_buffers USING GIST (geom);


-- 3) Subtract buffers from step 2 from merged lines from step 1...
CREATE TEMP TABLE traffic_sign_segments AS

-- a) for roads
WITH road_segments_pre AS (
    SELECT
        row_number() OVER () AS id,
        w.country_code, w.main_signs, w.sign_list, w.highway, w.oneway, w."oneway:bicycle",
        (ST_Dump(ST_Difference(w.geom, ST_Union(intersection_buffers.geom)))).geom AS geom
    FROM merged_ways w
    JOIN intersection_buffers
    ON ST_Intersects(w.geom, intersection_buffers.geom)
    WHERE
        w.highway_type = 'road'
        AND intersection_buffers.intersection_type = 'road'
    GROUP BY w.geom, w.country_code, w.main_signs, w.sign_list, w.highway, w.oneway, w."oneway:bicycle"
),

-- exclude short road segments
road_segments AS (
    SELECT *
    FROM road_segments_pre
    WHERE ST_Length(geom) > 10
),

-- b) for all other ways
way_segments AS (
    SELECT
        row_number() OVER () AS id,
        w.country_code, w.main_signs, w.sign_list, w.highway, w.oneway, w."oneway:bicycle",
        (ST_Dump(ST_Difference(w.geom, ST_Union(intersection_buffers.geom)))).geom AS geom
    FROM merged_ways w
    JOIN intersection_buffers
    ON ST_Intersects(w.geom, intersection_buffers.geom)
    WHERE
        w.highway_type = 'way'
    GROUP BY w.geom, w.country_code, w.main_signs, w.sign_list, w.highway, w.oneway, w."oneway:bicycle"
)

-- Merge pre-processed road and way segments
SELECT *
FROM road_segments
UNION ALL
SELECT *
FROM way_segments;

CREATE INDEX traffic_sign_segments_geom_idx ON traffic_sign_segments USING GIST (geom);


-- 4) Extract start-/endpoints to place taffic sign nodes
DROP TABLE IF EXISTS traffic_sign_nodes_way;

CREATE TABLE traffic_sign_nodes_way AS

-- for oneway roads with bidirectional bicycle traffic: define a list of cycling related traffic sign id's
WITH bicycle_ids AS (
    SELECT unnest(ARRAY['244.1']) AS sign_id
),
endpoints_all AS (
    -- place a traffic sign node at the start of each segment (except of oneway roads with oneway=-1)
    SELECT
        ST_StartPoint(segments.geom) AS geom,
        segments.id,
        segments.country_code,
        segments.sign_list,
        segments.main_signs,
        segments.highway,
        DEGREES(ST_Azimuth(ST_PointN(segments.geom, 2), ST_StartPoint(segments.geom)))::INT AS direction
    FROM traffic_sign_segments segments, bicycle_ids
    WHERE
        ST_NPoints(segments.geom) > 1
        -- take oneway:bicycle into account in contraflow oneway roads: place traffic signs in both directions, that are related to bicycle traffic
        AND (
            (segments.oneway IS NULL OR segments.oneway != '-1')
            OR (segments."oneway:bicycle" = 'no' AND segments.sign_list LIKE '%' || bicycle_ids.sign_id || '%')
        )
    UNION ALL
    -- place a traffic sign node at the end of each segment (except of oneway roads)
    -- TODO: take oneway:bicycle into account (place traffic signs in both directions, that are related to bicycle traffic)
    SELECT
        ST_EndPoint(segments.geom) AS geom,
        segments.id,
        segments.country_code,
        segments.sign_list,
        segments.main_signs,
        segments.highway,
        DEGREES(ST_Azimuth(ST_PointN(geom, ST_NPoints(geom) - 1), ST_EndPoint(geom)))::INT AS direction
    FROM traffic_sign_segments segments, bicycle_ids
    WHERE
        ST_NPoints(segments.geom) > 1
        AND (
            (segments.oneway IS NULL OR segments.oneway != 'yes')
            OR (segments."oneway:bicycle" = 'no' AND segments.sign_list LIKE '%' || bicycle_ids.sign_id || '%')
        )
),
endpoints AS (
    -- Extract start-/end points that are not connected to other lines
    SELECT endpoints_all.*
    FROM endpoints_all
    LEFT JOIN traffic_sign_segments segments
        ON endpoints_all.geom = ST_StartPoint(segments.geom) 
        OR endpoints_all.geom = ST_EndPoint(segments.geom)
    WHERE (segments.id = endpoints_all.id)
)
SELECT
    row_number() OVER () AS id, -- distinct id for identifying the closest highway line in the next step
    endpoints.geom,
    999 AS osm_id,
    endpoints.country_code,
    endpoints.sign_list,
    endpoints.main_signs,
    endpoints.highway,
    endpoints.direction,
    NULL AS layer
FROM endpoints;

-- Adopt osm_id and layer from the highway segment the traffic sign node was placed on
UPDATE traffic_sign_nodes_way
SET osm_id = closest_way.osm_id,
    layer = closest_way.layer
FROM (
    SELECT signs.id AS id, highway.osm_id, highway.layer
    FROM traffic_sign_nodes_way signs
    -- geometrically, placed notes aren't exactly intersecting the line in every case, so let's take the closest line
    JOIN highway
        ON ST_DWithin(signs.geom, highway.geom, 0.1)
    ORDER BY ST_Distance(signs.geom, highway.geom)
    -- LIMIT 1
) AS closest_way
WHERE traffic_sign_nodes_way.id = closest_way.id;

CREATE INDEX traffic_sign_nodes_way_geom_idx ON traffic_sign_nodes_way USING GIST (geom);

END; -- delete temporary tables