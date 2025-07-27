#!/bin/bash

# Nombre de la imagen
IMAGE_NAME="aseprite"

# Carpeta local para almacenar los archivos copiados
OUTPUT_DIR="./output"
ASEPRITE_SHARE_DIR="./aseprite_share"

# Asegúrate de que la carpeta de salida esté vacía
rm -rf "$OUTPUT_DIR"
rm -rf "$ASEPRITE_SHARE_DIR"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$ASEPRITE_SHARE_DIR"

# Construir la imagen con buildx
echo "Construyendo la imagen Docker..."
docker buildx build --platform linux/amd64 -t "$IMAGE_NAME" .

# Verificar si la compilación fue exitosa
if [ $? -ne 0 ]; then
  echo "Error al construir la imagen Docker."
  exit 1
fi

# Copiar el binario de /output al directorio local
echo "Copiando el binario a la carpeta local..."
docker cp $(docker create "$IMAGE_NAME"):"/output/aseprite" "$OUTPUT_DIR/aseprite"

# Copiar la carpeta de recursos /usr/local/share/aseprite/ al directorio local
echo "Copiando los recursos de Aseprite..."
docker cp $(docker create "$IMAGE_NAME"):"/usr/local/share/aseprite" "$ASEPRITE_SHARE_DIR/"

echo "¡Listo! Los archivos se han copiado a:"
echo "  - Binario Aseprite: $OUTPUT_DIR/aseprite"
echo "  - Recursos: $ASEPRITE_SHARE_DIR"

# Confirmación para eliminar la imagen
read -p "¿Deseas eliminar la imagen Docker '$IMAGE_NAME'? (s/n): " confirmacion

if [[ "$confirmacion" =~ ^[Ss]$ ]]; then
  # Eliminar la imagen Docker
  echo "Eliminando la imagen Docker: $IMAGE_NAME..."
  docker rmi "$IMAGE_NAME"
  echo "Imagen eliminada correctamente."
else
  echo "La imagen no se ha eliminado."
fi
