-- Finaly, merge different traffic sign node tables for stand alone nodes, roads/ways and zones
-----------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS traffic_signs;

CREATE TABLE traffic_signs AS
SELECT geom, country_code, sign_list, main_signs, direction, osm_id, highway, 'node' AS source
FROM traffic_sign_node
UNION ALL
SELECT geom, country_code, sign_list, main_signs, direction, osm_id, highway, 'way' AS source
FROM traffic_sign_nodes_way way
-- exclude traffic signs derived from the centerline if the traffic sign is already mapped as a separate node (and has similar direction)
WHERE NOT EXISTS (
    SELECT 1
    FROM traffic_sign_node node
    WHERE ST_DWithin(way.geom, node.geom, 8) 
    AND way.main_signs = node.main_signs
    AND ABS(way.direction - node.direction) <= 45
)
UNION ALL
SELECT geom, country_code, sign_list, main_signs, direction, osm_id, highway, 'zone' AS source
FROM traffic_sign_nodes_zone zone
WHERE NOT EXISTS (
    SELECT 1
    FROM traffic_sign_node node
    WHERE ST_DWithin(zone.geom, node.geom, 8) 
    AND zone.main_signs = node.main_signs
    AND ABS(zone.direction - node.direction) <= 45
);

CREATE INDEX traffic_signs_geom_idx ON traffic_signs USING GIST (geom);