#!/bin/bash

#-----------#
# variables #
#-----------#

# postgres database specifications
DB_NAME="traffic_sign"
DB_USER="postgres"
DB_HOST="localhost"

# .pgpass file for database access: https://www.postgresql.org/docs/current/libpq-pgpass.html
export PGPASSFILE=$HOME/.pgpass

# directories
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OSM_DATA_DIR="$DIR/osm"

# lua file for osm2pgsql import
IMPORT_LUA="lua/osm_import_traffic_sign.lua"

# parameters
DATA_SOURCE="false"     # -d (arg: URL or path to osm pbf data file): Source for osm database import. If an URL is passed, fresh osm data will be downloaded from that source (e.g. "-d https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf"). If an osm file path is passed, data will be importet from that file (e.g. "-d osm/berlin-latest.osm.pbf"). If no source is passed, just processing will be performed in the existing database.
DATA_EXTRACT="false"    # -e (arg: bounding box for extract): If set, database import is using an osmium data extract for the passed bounding box from the data source (e.g. "-e 13.3924,52.4543,13.4859,52.5009").
DB_REFRESH="false"      # -r (no arg): If set, a database refresh will be performed (delete and renew all tables). Useful for development and debugging.
SKIP_PROCESSING="false" # -s (no arg): If set, sql data processing will be skipped. Useful for development and debugging.

echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Start script for updating strassenraumkarte data..."

# check parameter from script call:
while getopts "d:e:rs" opt; do
  case "$opt" in
    d)
      DATA_SOURCE="$OPTARG"
      ;;
    e)
      if [ "$DATA_SOURCE" = "false" ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S')  [WARNING] Passed extract parameter, but no data source. Skipping extract."
      else
        DATA_EXTRACT="$OPTARG"
      fi
      ;;
    r)
      DB_REFRESH="true"
      ;;
    s)
      SKIP_PROCESSING="true"
      ;;
    *)
      echo "$(date +'%Y-%m-%d %H:%M:%S')  [WARNING] Unknown parameter: -$OPTARG" >&2
      ;;
  esac
done

# check data source:
if ! [ "$DATA_SOURCE" = "false" ]; then
  OSM_FILENAME=$(basename "$DATA_SOURCE")
  OSM_FILE="$OSM_DATA_DIR/$OSM_FILENAME"

  # if it's an URL, download data
  if [[ "$DATA_SOURCE" =~ ^(http|https|ftp):// ]]; then
    wget --spider -q $DATA_SOURCE
    if [[ $? -eq 0 ]]; then
      echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Downloading osm data for data import..."
      wget -O $OSM_FILE $DATA_SOURCE
    else
      echo "$(date +'%Y-%m-%d %H:%M:%S')  [ERROR] Data source URL "$DATA_SOURCE" isn't valid/reachable. Aborting script."
      exit 1
    fi

  # if it's a local file path, use this data
  elif [[ -e "$DATA_SOURCE" ]]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Using osm file for data import..."

  # abort if no valid data source is passed
  else
    echo "$(date +'%Y-%m-%d %H:%M:%S')  [ERROR] OSM data source "$DATA_SOURCE" isn't existing (neither a URL nor a valid local file path). Aborting script."
    exit 1
  fi

  # if required, extract area of interest from data source
  if ! [ "$DATA_EXTRACT" = "false" ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Create osm data extract..."
    EXTRACT_FILE="$OSM_DATA_DIR/extract_$OSM_FILENAME"
    osmium extract -b $DATA_EXTRACT $OSM_FILE -o $EXTRACT_FILE -O -s smart
    IMPORT_FILE=$EXTRACT_FILE
  else
    IMPORT_FILE=$OSM_FILE
  fi
fi

# if required, refresh database
if [ "$DB_REFRESH" = "true" ]; then
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Refresh database..."
  psql -U $DB_USER -h $DB_HOST -d $DB_NAME -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public; CREATE EXTENSION postgis;"
fi

# import data if valid data source was provided
if ! [[ -z "$IMPORT_FILE" ]]; then
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Importing OSM Data..."
  osm2pgsql -c -H localhost -U postgres -d $DB_NAME -O flex -S $IMPORT_LUA $IMPORT_FILE
fi

# processing data (bunch of SQL processing steps for rendering and styling)
if [ "$SKIP_PROCESSING" = "true" ]; then
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Skipped OSM Data Processing."
else
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Processing OSM Traffic Sign Data..."

  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - traffic sign nodes..."
  psql -U $DB_USER -h $DB_HOST -d $DB_NAME < "sql/traffic_sign_node.sql"

  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - traffic sign ways..."
  psql -U $DB_USER -h $DB_HOST -d $DB_NAME < "sql/traffic_sign_way.sql"

  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - traffic sign zones..."
  psql -U $DB_USER -h $DB_HOST -d $DB_NAME < "sql/traffic_sign_zone.sql"

  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - merge data..."
  psql -U $DB_USER -h $DB_HOST -d $DB_NAME < "sql/merge.sql"
fi

echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Script completed."
exit 0