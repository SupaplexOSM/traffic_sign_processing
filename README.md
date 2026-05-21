# OSM traffic sign processing
**Extract traffic sign locations and directions from OSM data.**

## How it works

Run `data_preparation_traffic_sign.sh` (see below) to load and process the data. It's downloading or importing OSM road and traffic sign data into a PostGIS DB via osm2pgsql and does some SQL processing to derive traffic sign locations.

## Example bash commands

- Refresh database, download new data for Berlin, extract data for Neukölln suburb before data import and processing:
```./data_preparation_traffic_sign.sh -r -d https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf -e 13.3924,52.4543,13.4859,52.5009
```

- Use an existent osm extract for data import and processing
```./data_preparation_traffic_sign.sh -d osm/extract_berlin-latest.osm.pbf
```
