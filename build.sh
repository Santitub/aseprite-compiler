#!/usr/bin/env bash
# ============================================================================
# SCRIPT DE COMPILACIÓN DE ASEPRITE
# Autor: Santitub
# Descripción: Compila Aseprite desde código fuente usando Docker
# Uso: ./build.sh [opciones]
# ============================================================================

# ----------------------------------------------------------------------------
# CONFIGURACIÓN ESTRICTA
# ----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# VARIABLES DE CONFIGURACIÓN
# ----------------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Configuración de Docker
readonly IMAGE_NAME="aseprite-builder"
readonly IMAGE_TAG="latest"
readonly FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

# Directorios de salida
readonly OUTPUT_DIR="${SCRIPT_DIR}/output"

# URLs de GitHub
readonly GITHUB_API_URL="https://api.github.com/repos/aseprite/aseprite/releases/latest"
readonly GITHUB_RELEASES_URL="https://github.com/aseprite/aseprite/releases/latest"
readonly SKIA_RELEASES_API="https://api.github.com/repos/aseprite/skia/releases"

# Configuración de versiones (modificables)
ASEPRITE_VERSION="${ASEPRITE_VERSION:-}"
SKIA_VERSION="${SKIA_VERSION:-}"
SKIP_CLEANUP="${SKIP_CLEANUP:-false}"
VERBOSE="${VERBOSE:-false}"

# Configuración de build
BUILD_TIMEOUT="${BUILD_TIMEOUT:-3600}"  # 1 hora por defecto
DOCKER_PROGRESS="${DOCKER_PROGRESS:-plain}"  # plain, tty, auto

# Variables de estado
NEED_SUDO=false
USE_BUILDX=false
DOCKER_CMD="docker"

# Mapeo de versiones Aseprite -> Skia (compatibilidad conocida)
declare -A SKIA_COMPAT_MAP=(
    ["v1.3.15"]="m124-08a5439a6b"
    ["v1.3.14"]="m124-08a5439a6b"
    ["v1.3.13"]="m124-08a5439a6b"
    ["v1.3.12"]="m124-08a5439a6b"
    ["v1.3.11"]="m124-08a5439a6b"
    ["v1.3.10"]="m124-08a5439a6b"
    ["v1.3.9"]="m102-861e4743af"
    ["v1.3.8"]="m102-861e4743af"
    ["v1.3.7"]="m102-861e4743af"
    ["v1.3.6"]="m102-861e4743af"
    ["v1.3.5"]="m102-861e4743af"
    ["v1.3.4"]="m102-861e4743af"
    ["v1.3.3"]="m102-861e4743af"
    ["v1.3.2"]="m102-861e4743af"
    ["v1.3"]="m102-861e4743af"
    ["v1.2"]="m96-1e2bef7700"
)

# Versión de Skia por defecto para versiones nuevas
DEFAULT_SKIA_VERSION="m124-08a5439a6b"

# ----------------------------------------------------------------------------
# COLORES Y FORMATO
# ----------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

# ----------------------------------------------------------------------------
# FUNCIONES DE UTILIDAD
# ----------------------------------------------------------------------------

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "$level" in
        INFO)    echo -e "${BLUE}[${timestamp}]${NC} ${GREEN}[INFO]${NC}    $message" >&2 ;;
        WARN)    echo -e "${BLUE}[${timestamp}]${NC} ${YELLOW}[WARN]${NC}    $message" >&2 ;;
        ERROR)   echo -e "${BLUE}[${timestamp}]${NC} ${RED}[ERROR]${NC}   $message" >&2 ;;
        SUCCESS) echo -e "${BLUE}[${timestamp}]${NC} ${GREEN}[SUCCESS]${NC} $message" >&2 ;;
        DEBUG)   
            if [[ "$VERBOSE" == "true" ]]; then
                echo -e "${BLUE}[${timestamp}]${NC} ${PURPLE}[DEBUG]${NC}   $message" >&2
            fi
            ;;
        *)       echo -e "${BLUE}[${timestamp}]${NC} $message" >&2 ;;
    esac
}

# Función para ejecutar comandos en modo verbose
run_cmd() {
    if [[ "$VERBOSE" == "true" ]]; then
        log DEBUG "Ejecutando: $*"
        "$@"
    else
        "$@"
    fi
}

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
    ╔═══════════════════════════════════════════════════════════════╗
    ║                                                               ║
    ║     █████╗ ███████╗███████╗██████╗ ██████╗ ██╗████████╗███████╗║
    ║    ██╔══██╗██╔════╝██╔════╝██╔══██╗██╔══██╗██║╚══██╔══╝██╔════╝║
    ║    ███████║███████╗█████╗  ██████╔╝██████╔╝██║   ██║   █████╗  ║
    ║    ██╔══██║╚════██║██╔══╝  ██╔═══╝ ██╔══██╗██║   ██║   ██╔══╝  ║
    ║    ██║  ██║███████║███████╗██║     ██║  ██║██║   ██║   ███████╗║
    ║    ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝║
    ║                                                               ║
    ║                    BUILDER v3.0                               ║
    ║                                                               ║
    ╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

show_usage() {
    cat << EOF
${WHITE}Uso:${NC} $SCRIPT_NAME [opciones]

${WHITE}Opciones:${NC}
    -h, --help              Mostrar esta ayuda
    -v, --verbose           Modo verbose (más información)
    -V, --version VERSION   Especificar versión de Aseprite (default: latest)
    -S, --skia VERSION      Especificar versión de Skia (default: auto)
    -s, --skip-cleanup      No preguntar por eliminar imagen al final
    -c, --clean             Limpiar todo (imágenes, contenedores, output)
    -l, --list-versions     Mostrar últimas versiones disponibles
    -t, --timeout SECONDS   Timeout para el build (default: 3600)
    
${WHITE}Variables de entorno:${NC}
    ASEPRITE_VERSION        Versión de Aseprite a compilar
    SKIA_VERSION            Versión de Skia a usar
    SKIP_CLEANUP            Si es "true", no elimina la imagen al final
    VERBOSE                 Si es "true", muestra más información
    BUILD_TIMEOUT           Timeout en segundos para el build
    DOCKER_PROGRESS         Modo de progreso de Docker (plain, tty, auto)

${WHITE}Ejemplos:${NC}
    $SCRIPT_NAME                              # Compilar última versión
    $SCRIPT_NAME -V v1.3.7                    # Compilar versión específica
    $SCRIPT_NAME -V v1.3.7 -S m102-861e4743af # Versión específica de Skia
    $SCRIPT_NAME -v -s                        # Modo verbose, sin preguntar cleanup
    $SCRIPT_NAME -l                           # Listar versiones disponibles
    VERBOSE=true $SCRIPT_NAME                 # Usando variable de entorno
EOF
}

# ----------------------------------------------------------------------------
# VERIFICACIÓN DE ARQUITECTURA
# ----------------------------------------------------------------------------

check_architecture() {
    log INFO "Verificando arquitectura del sistema..."
    
    local arch
    arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64)
            log SUCCESS "Arquitectura compatible: $arch (x86_64)"
            ;;
        aarch64|arm64)
            log WARN "Arquitectura ARM detectada: $arch"
            log WARN "La compilación usará emulación QEMU (muy lenta, 2-4 horas)."
            log WARN "Considera compilar en una máquina x86_64."
            echo ""
            read -r -p "¿Deseas continuar de todos modos? (s/n): " confirm
            if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
                log INFO "Operación cancelada."
                exit 0
            fi
            ;;
        *)
            log ERROR "Arquitectura no soportada: $arch"
            log ERROR "Este script solo soporta x86_64 (amd64) y arm64."
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------------------
# CONFIGURACIÓN DE DOCKER
# ----------------------------------------------------------------------------

setup_docker_command() {
    if [[ "$NEED_SUDO" == "true" ]]; then
        DOCKER_CMD="sudo docker"
    else
        DOCKER_CMD="docker"
    fi
    log DEBUG "Comando Docker configurado: $DOCKER_CMD"
}

# Ejecutar docker con o sin sudo
run_docker() {
    if [[ "$NEED_SUDO" == "true" ]]; then
        sudo docker "$@"
    else
        docker "$@"
    fi
}

check_docker_permissions() {
    log INFO "Verificando permisos de Docker..."
    
    if ! command -v docker &> /dev/null; then
        log ERROR "Docker no está instalado."
        log ERROR "Por favor, instala Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    if docker info &> /dev/null 2>&1; then
        log SUCCESS "Docker funciona sin privilegios elevados."
        NEED_SUDO=false
        setup_docker_command
        return 0
    fi
    
    log WARN "Docker requiere privilegios elevados (sudo)."
    
    if ! command -v sudo &> /dev/null; then
        log ERROR "sudo no está disponible y Docker requiere privilegios elevados."
        log ERROR "Opciones:"
        log ERROR "  1. Ejecuta este script como root"
        log ERROR "  2. Añade tu usuario al grupo docker: sudo usermod -aG docker \$USER"
        exit 1
    fi
    
    echo ""
    echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│  Docker requiere privilegios de administrador (sudo)            │${NC}"
    echo -e "${YELLOW}│                                                                 │${NC}"
    echo -e "${YELLOW}│  Se te pedirá la contraseña para ejecutar comandos Docker.      │${NC}"
    echo -e "${YELLOW}│                                                                 │${NC}"
    echo -e "${YELLOW}│  Para evitar esto en el futuro, ejecuta:                        │${NC}"
    echo -e "${YELLOW}│    sudo usermod -aG docker \$USER                                │${NC}"
    echo -e "${YELLOW}│  Y luego cierra sesión y vuelve a iniciar.                      │${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    log INFO "Solicitando credenciales de sudo..."
    
    if sudo -v; then
        log SUCCESS "Credenciales de sudo validadas."
        NEED_SUDO=true
        setup_docker_command
        
        # Mantener sudo activo con timeout extendido
        (
            while true; do
                sudo -n true 2>/dev/null
                sleep 50
                kill -0 "$$" 2>/dev/null || exit
            done
        ) &
        
        return 0
    else
        log ERROR "No se pudieron validar las credenciales de sudo."
        exit 1
    fi
}

check_docker_running() {
    log INFO "Verificando que Docker está activo..."
    
    # Pequeña pausa para asegurar que sudo esté listo
    sleep 1
    
    local docker_output
    local docker_exit_code
    
    # Capturar salida y código de error
    if [[ "$NEED_SUDO" == "true" ]]; then
        docker_output=$(sudo docker info 2>&1) && docker_exit_code=0 || docker_exit_code=$?
    else
        docker_output=$(docker info 2>&1) && docker_exit_code=0 || docker_exit_code=$?
    fi
    
    if [[ $docker_exit_code -eq 0 ]]; then
        log SUCCESS "Docker está activo y funcionando."
        return 0
    fi
    
    log ERROR "Docker no está respondiendo correctamente."
    log DEBUG "Salida de docker info: $docker_output"
    
    if command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet docker 2>/dev/null; then
            log WARN "El servicio Docker está activo pero no responde."
            log WARN "Esto puede ser un problema de permisos del socket."
            
            # Mostrar información del socket
            if [[ -S /var/run/docker.sock ]]; then
                local socket_info
                socket_info=$(ls -la /var/run/docker.sock 2>/dev/null || echo "No disponible")
                log DEBUG "Socket Docker: $socket_info"
            fi
        else
            log ERROR "El servicio Docker no está activo."
            log ERROR "Inicia el servicio con: sudo systemctl start docker"
        fi
    fi
    
    exit 1
}

check_docker_buildx() {
    log INFO "Verificando Docker Buildx..."
    
    if run_docker buildx version > /dev/null 2>&1; then
        USE_BUILDX=true
        log SUCCESS "Docker Buildx disponible."
    else
        USE_BUILDX=false
        log WARN "Docker Buildx no disponible. Usando build clásico."
    fi
}

# ----------------------------------------------------------------------------
# MANEJO DE VERSIONES
# ----------------------------------------------------------------------------

get_latest_version() {
    log INFO "Obteniendo última versión de Aseprite desde GitHub..."
    
    local version=""
    
    if command -v curl &> /dev/null; then
        log DEBUG "Intentando con GitHub API..."
        
        version=$(curl -sL --connect-timeout 10 "$GITHUB_API_URL" 2>/dev/null | \
            grep -o '"tag_name": *"[^"]*"' | \
            head -1 | \
            sed 's/"tag_name": *"\([^"]*\)"/\1/')
        
        if [[ -n "$version" ]]; then
            log DEBUG "Versión obtenida via API: $version"
            echo "$version"
            return 0
        fi
        
        log DEBUG "API falló, intentando con redirección..."
        
        version=$(curl -sIL --connect-timeout 10 "$GITHUB_RELEASES_URL" 2>/dev/null | \
            grep -i "^location:" | \
            tail -1 | \
            sed 's/.*\/tag\///' | \
            tr -d '\r\n ')
        
        if [[ -n "$version" ]]; then
            log DEBUG "Versión obtenida via redirección: $version"
            echo "$version"
            return 0
        fi
    fi
    
    if command -v wget &> /dev/null; then
        log DEBUG "Intentando con wget..."
        
        version=$(wget -qO- --timeout=10 "$GITHUB_API_URL" 2>/dev/null | \
            grep -o '"tag_name": *"[^"]*"' | \
            head -1 | \
            sed 's/"tag_name": *"\([^"]*\)"/\1/')
        
        if [[ -n "$version" ]]; then
            log DEBUG "Versión obtenida via wget: $version"
            echo "$version"
            return 0
        fi
    fi
    
    log ERROR "No se pudo obtener la última versión de Aseprite."
    log ERROR "Verifica tu conexión a internet o especifica una versión manualmente con -V"
    return 1
}

# Verificar que una versión existe en GitHub
verify_version_exists() {
    local version="$1"
    
    log INFO "Verificando que la versión $version existe..."
    
    local http_code
    http_code=$(curl -sL -o /dev/null -w "%{http_code}" \
        "https://api.github.com/repos/aseprite/aseprite/releases/tags/${version}" 2>/dev/null)
    
    if [[ "$http_code" == "200" ]]; then
        log SUCCESS "Versión $version verificada en GitHub."
        return 0
    else
        log ERROR "La versión $version no existe en GitHub (HTTP $http_code)."
        log ERROR "Usa --list-versions para ver versiones disponibles."
        return 1
    fi
}

# Obtener versión de Skia compatible
get_compatible_skia_version() {
    local aseprite_version="$1"
    
    # Extraer versión base (v1.3.15.4 -> v1.3.15, v1.3.7 -> v1.3.7)
    local base_version
    base_version=$(echo "$aseprite_version" | sed -E 's/^(v[0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')
    
    log DEBUG "Buscando Skia compatible para Aseprite $aseprite_version (base: $base_version)"
    
    # Buscar en el mapa de compatibilidad
    if [[ -n "${SKIA_COMPAT_MAP[$base_version]:-}" ]]; then
        echo "${SKIA_COMPAT_MAP[$base_version]}"
        return 0
    fi
    
    # Para versiones v1.3.x no mapeadas, usar la más reciente
    if [[ "$base_version" =~ ^v1\.3 ]]; then
        echo "$DEFAULT_SKIA_VERSION"
        return 0
    fi
    
    # Para versiones muy antiguas v1.2.x
    if [[ "$base_version" =~ ^v1\.2 ]]; then
        echo "m96-1e2bef7700"
        return 0
    fi
    
    # Default para versiones desconocidas
    log WARN "Versión no mapeada, usando Skia por defecto: $DEFAULT_SKIA_VERSION"
    echo "$DEFAULT_SKIA_VERSION"
}

# Verificar que la versión de Skia existe
verify_skia_version() {
    local skia_version="$1"
    
    log INFO "Verificando que Skia $skia_version existe..."
    
    local http_code
    http_code=$(curl -sL -o /dev/null -w "%{http_code}" \
        "https://github.com/aseprite/skia/releases/download/${skia_version}/Skia-Linux-Release-x64.zip" 2>/dev/null)
    
    if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
        log SUCCESS "Skia $skia_version verificada."
        return 0
    else
        log ERROR "Skia $skia_version no encontrada (HTTP $http_code)."
        return 1
    fi
}

list_versions() {
    log INFO "Obteniendo lista de versiones de Aseprite..."
    
    echo ""
    echo -e "${WHITE}Últimas versiones disponibles:${NC}"
    echo ""
    
    if command -v curl &> /dev/null; then
        local versions
        versions=$(curl -sL "https://api.github.com/repos/aseprite/aseprite/releases" 2>/dev/null | \
            grep -o '"tag_name": *"[^"]*"' | \
            head -10 | \
            sed 's/"tag_name": *"\([^"]*\)"/\1/')
        
        if [[ -n "$versions" ]]; then
            local first=true
            while IFS= read -r ver; do
                local base_ver
                base_ver=$(echo "$ver" | sed -E 's/^(v[0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')
                local skia_ver="${SKIA_COMPAT_MAP[$base_ver]:-$DEFAULT_SKIA_VERSION}"
                
                if [[ "$first" == true ]]; then
                    echo -e "  ${GREEN}➜ $ver${NC} (latest) - Skia: $skia_ver"
                    first=false
                else
                    echo -e "  ${CYAN}  $ver${NC} - Skia: $skia_ver"
                fi
            done <<< "$versions"
            echo ""
            return 0
        fi
    fi
    
    log ERROR "No se pudieron obtener las versiones."
    return 1
}

validate_version() {
    local version="$1"
    
    if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?(\.[0-9]+)?(-[a-zA-Z0-9]+)?$ ]]; then
        log WARN "El formato de versión '$version' podría no ser válido."
        log WARN "Formato esperado: v1.3.7, v1.3.15.4, v1.3.7-beta, etc."
        
        read -r -p "¿Deseas continuar de todos modos? (s/n): " confirm
        if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
            log INFO "Operación cancelada."
            exit 0
        fi
    fi
}

setup_versions() {
    # Configurar versión de Aseprite
    if [[ -z "$ASEPRITE_VERSION" ]]; then
        log INFO "No se especificó versión, obteniendo la última..."
        
        ASEPRITE_VERSION=$(get_latest_version) || {
            log ERROR "No se pudo determinar la versión a compilar."
            exit 1
        }
        
        log SUCCESS "Versión detectada: $ASEPRITE_VERSION"
    else
        log INFO "Versión especificada por usuario: $ASEPRITE_VERSION"
        validate_version "$ASEPRITE_VERSION"
        verify_version_exists "$ASEPRITE_VERSION" || exit 1
    fi
    
    # Configurar versión de Skia
    if [[ -z "$SKIA_VERSION" ]]; then
        log INFO "Determinando versión de Skia compatible..."
        SKIA_VERSION=$(get_compatible_skia_version "$ASEPRITE_VERSION")
        log SUCCESS "Skia seleccionada: $SKIA_VERSION"
    else
        log INFO "Versión de Skia especificada: $SKIA_VERSION"
    fi
    
    # Verificar que Skia existe
    verify_skia_version "$SKIA_VERSION" || {
        log ERROR "La versión de Skia especificada no es válida."
        exit 1
    }
}

# ----------------------------------------------------------------------------
# VERIFICACIONES DEL SISTEMA
# ----------------------------------------------------------------------------

check_basic_dependencies() {
    log INFO "Verificando dependencias básicas..."
    
    local deps=("curl" "grep" "sed")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log WARN "Dependencias opcionales faltantes: ${missing[*]}"
        log WARN "Algunas funcionalidades podrían no estar disponibles."
    fi
    
    log SUCCESS "Verificación de dependencias básicas completada."
}

check_disk_space() {
    log INFO "Verificando espacio en disco..."
    
    local required_gb=15
    local available_kb
    available_kb=$(df "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    local available_gb=$((available_kb / 1024 / 1024))
    
    if [[ $available_gb -lt $required_gb ]]; then
        log WARN "Espacio disponible: ${available_gb}GB. Recomendado: ${required_gb}GB"
        read -r -p "¿Deseas continuar de todos modos? (s/n): " confirm
        if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
            log INFO "Operación cancelada por el usuario."
            exit 0
        fi
    else
        log SUCCESS "Espacio en disco suficiente: ${available_gb}GB disponibles."
    fi
}

prepare_directories() {
    log INFO "Preparando directorios de salida..."
    
    if [[ -d "$OUTPUT_DIR" ]]; then
        log DEBUG "Eliminando directorio de salida anterior..."
        rm -rf "$OUTPUT_DIR"
    fi
    
    mkdir -p "$OUTPUT_DIR"
    
    log SUCCESS "Directorios preparados: $OUTPUT_DIR"
}

# ----------------------------------------------------------------------------
# CONSTRUCCIÓN Y EXTRACCIÓN
# ----------------------------------------------------------------------------

build_docker_image() {
    log INFO "Construyendo imagen Docker..."
    log INFO "Versión de Aseprite: ${ASEPRITE_VERSION}"
    log INFO "Versión de Skia: ${SKIA_VERSION}"
    log INFO "Timeout: ${BUILD_TIMEOUT}s"
    log INFO "Este proceso puede tardar 15-45 minutos dependiendo de tu hardware..."
    
    local -a build_args=(
        --build-arg "ASEPRITE_VERSION=${ASEPRITE_VERSION}"
        --build-arg "SKIA_VERSION=${SKIA_VERSION}"
        --target runtime
        -t "$FULL_IMAGE_NAME"
        -f "${SCRIPT_DIR}/Dockerfile"
        "--progress=${DOCKER_PROGRESS}"
        "$SCRIPT_DIR"
    )
    
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    INICIANDO COMPILACIÓN                        ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local build_status=0
    
    if [[ "$USE_BUILDX" == "true" ]]; then
        log DEBUG "Usando buildx build"
        
        # Construir comando completo para timeout
        if command -v timeout &> /dev/null && [[ -n "$BUILD_TIMEOUT" ]]; then
            if [[ "$NEED_SUDO" == "true" ]]; then
                timeout "$BUILD_TIMEOUT" sudo docker buildx build --platform linux/amd64 "${build_args[@]}" || build_status=$?
            else
                timeout "$BUILD_TIMEOUT" docker buildx build --platform linux/amd64 "${build_args[@]}" || build_status=$?
            fi
        else
            run_docker buildx build --platform linux/amd64 "${build_args[@]}" || build_status=$?
        fi
    else
        log DEBUG "Usando build clásico"
        
        if command -v timeout &> /dev/null && [[ -n "$BUILD_TIMEOUT" ]]; then
            if [[ "$NEED_SUDO" == "true" ]]; then
                timeout "$BUILD_TIMEOUT" sudo docker build "${build_args[@]}" || build_status=$?
            else
                timeout "$BUILD_TIMEOUT" docker build "${build_args[@]}" || build_status=$?
            fi
        else
            run_docker build "${build_args[@]}" || build_status=$?
        fi
    fi
    
    # Verificar resultado
    if [[ $build_status -eq 0 ]]; then
        echo ""
        log SUCCESS "Imagen Docker construida exitosamente."
    elif [[ $build_status -eq 124 ]]; then
        log ERROR "Timeout alcanzado (${BUILD_TIMEOUT}s). El build tardó demasiado."
        log ERROR "Incrementa BUILD_TIMEOUT o verifica recursos del sistema."
        exit 1
    else
        log ERROR "Error al construir la imagen Docker (código: $build_status)."
        exit 1
    fi
}

# Aplicar permisos correctos a los archivos extraídos
fix_permissions() {
    local target_path="$1"
    
    log DEBUG "Aplicando permisos a: $target_path"
    
    if [[ "$NEED_SUDO" == "true" ]]; then
        sudo chown -R "$USER:$USER" "$target_path"
    fi
    
    # Asegurar que el binario sea ejecutable
    if [[ -f "$target_path" && ! -d "$target_path" ]]; then
        chmod +x "$target_path" 2>/dev/null || sudo chmod +x "$target_path"
    fi
}

extract_files() {
    log INFO "Extrayendo archivos del contenedor..."
    
    local container_id
    
    # Crear contenedor temporal
    container_id=$(run_docker create --entrypoint="" "$FULL_IMAGE_NAME" /bin/true)
    log DEBUG "Contenedor temporal creado: $container_id"
    
    cleanup_container() {
        log DEBUG "Limpiando contenedor temporal..."
        run_docker rm -f "$container_id" > /dev/null 2>&1 || true
    }
    
    trap 'cleanup_container' ERR
    
    # Copiar binario
    log INFO "Copiando binario de Aseprite..."
    if run_docker cp "${container_id}:/usr/local/bin/aseprite" "${OUTPUT_DIR}/aseprite"; then
        fix_permissions "${OUTPUT_DIR}/aseprite"
        log SUCCESS "Binario copiado: ${OUTPUT_DIR}/aseprite"
    else
        log ERROR "Error al copiar el binario."
        cleanup_container
        exit 1
    fi
    
    # Copiar datos/recursos
    log INFO "Copiando recursos de Aseprite..."
    if run_docker cp "${container_id}:/usr/local/share/aseprite/data" "${OUTPUT_DIR}/"; then
        fix_permissions "${OUTPUT_DIR}/data"
        log SUCCESS "Recursos copiados: ${OUTPUT_DIR}/data"
    else
        log ERROR "Error al copiar los recursos."
        cleanup_container
        exit 1
    fi
    
    cleanup_container
    trap - ERR
    
    log SUCCESS "Extracción completada."
}

verify_files() {
    log INFO "Verificando archivos extraídos..."
    
    local errors=0
    
    if [[ -f "${OUTPUT_DIR}/aseprite" ]]; then
        local size
        size=$(du -h "${OUTPUT_DIR}/aseprite" | cut -f1)
        log SUCCESS "Binario encontrado: ${OUTPUT_DIR}/aseprite ($size)"
        
        if [[ -x "${OUTPUT_DIR}/aseprite" ]]; then
            log SUCCESS "El binario tiene permisos de ejecución."
        else
            log WARN "El binario no tiene permisos de ejecución. Añadiendo..."
            chmod +x "${OUTPUT_DIR}/aseprite" 2>/dev/null || sudo chmod +x "${OUTPUT_DIR}/aseprite"
        fi
    else
        log ERROR "Binario no encontrado: ${OUTPUT_DIR}/aseprite"
        ((errors++))
    fi
    
    if [[ -d "${OUTPUT_DIR}/data" ]]; then
        local file_count
        file_count=$(find "${OUTPUT_DIR}/data" -type f | wc -l)
        log SUCCESS "Recursos encontrados: ${OUTPUT_DIR}/data ($file_count archivos)"
    else
        log ERROR "Recursos no encontrados: ${OUTPUT_DIR}/data"
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        log ERROR "Verificación fallida con $errors errores."
        exit 1
    fi
    
    log SUCCESS "Verificación completada exitosamente."
}

generate_run_script() {
    log INFO "Generando script de ejecución..."
    
    local run_script="${OUTPUT_DIR}/run-aseprite.sh"
    
    cat > "$run_script" << 'SCRIPT'
#!/usr/bin/env bash
# Script para ejecutar Aseprite
# Generado automáticamente

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASEPRITE_BIN="${SCRIPT_DIR}/aseprite"

if [[ ! -f "$ASEPRITE_BIN" ]]; then
    echo "Error: No se encontró el binario de Aseprite en: $ASEPRITE_BIN"
    exit 1
fi

if [[ ! -d "${SCRIPT_DIR}/data" ]]; then
    echo "Advertencia: No se encontró la carpeta data en: ${SCRIPT_DIR}/data"
fi

# Ejecutar desde el directorio donde está el binario
cd "$SCRIPT_DIR"
exec "./aseprite" "$@"
SCRIPT
    
    chmod +x "$run_script"
    log SUCCESS "Script de ejecución generado: $run_script"
}

generate_version_info() {
    log INFO "Generando archivo de información de versión..."
    
    local info_file="${OUTPUT_DIR}/version-info.txt"
    
    cat > "$info_file" << EOF
Aseprite Build Information
===========================
Fecha de compilación: $(date '+%Y-%m-%d %H:%M:%S')
Aseprite Version: ${ASEPRITE_VERSION}
Skia Version: ${SKIA_VERSION}
Sistema: $(uname -s) $(uname -m)
Docker Image: ${FULL_IMAGE_NAME}
EOF
    
    log SUCCESS "Información de versión: $info_file"
}

show_summary() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    COMPILACIÓN EXITOSA                        ║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  Aseprite: $(printf '%-49s' "$ASEPRITE_VERSION")║${NC}"
    echo -e "${GREEN}║  Skia:     $(printf '%-49s' "$SKIA_VERSION")║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}Archivos generados:${NC}"
    echo -e "  ${CYAN}➜${NC} Binario:   ${OUTPUT_DIR}/aseprite"
    echo -e "  ${CYAN}➜${NC} Recursos:  ${OUTPUT_DIR}/data/"
    echo -e "  ${CYAN}➜${NC} Ejecutar:  ${OUTPUT_DIR}/run-aseprite.sh"
    echo ""
    echo -e "${WHITE}Estructura:${NC}"
    echo -e "  ${OUTPUT_DIR}/"
    echo -e "  ├── aseprite"
    echo -e "  ├── data/"
    echo -e "  ├── run-aseprite.sh"
    echo -e "  └── version-info.txt"
    echo ""
    echo -e "${WHITE}Para ejecutar Aseprite:${NC}"
    echo -e "  ${YELLOW}${OUTPUT_DIR}/run-aseprite.sh${NC}"
    echo ""
    echo -e "${WHITE}O directamente:${NC}"
    echo -e "  ${YELLOW}cd ${OUTPUT_DIR} && ./aseprite${NC}"
    echo ""
}

cleanup_docker() {
    if [[ "$SKIP_CLEANUP" == "true" ]]; then
        log INFO "Limpieza automática desactivada (--skip-cleanup)."
        return
    fi
    
    echo ""
    read -r -p "¿Deseas eliminar la imagen Docker '${FULL_IMAGE_NAME}'? (s/n): " confirm
    
    if [[ "$confirm" =~ ^[Ss]$ ]]; then
        log INFO "Eliminando imagen Docker..."
        
        if run_docker rmi "$FULL_IMAGE_NAME" > /dev/null 2>&1; then
            log SUCCESS "Imagen eliminada: $FULL_IMAGE_NAME"
        else
            log WARN "No se pudo eliminar la imagen."
        fi
        
        log INFO "Limpiando imágenes huérfanas..."
        run_docker image prune -f > /dev/null 2>&1 || true
    else
        log INFO "Imagen conservada: $FULL_IMAGE_NAME"
    fi
}

full_cleanup() {
    log WARN "Realizando limpieza completa..."
    
    check_docker_permissions
    
    local containers
    containers=$(run_docker ps -a -q --filter "ancestor=$FULL_IMAGE_NAME" 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
        log INFO "Eliminando contenedores..."
        echo "$containers" | xargs -r run_docker rm -f > /dev/null 2>&1 || true
    fi
    
    if run_docker image inspect "$FULL_IMAGE_NAME" > /dev/null 2>&1; then
        log INFO "Eliminando imagen..."
        run_docker rmi -f "$FULL_IMAGE_NAME" > /dev/null 2>&1 || true
    fi
    
    if [[ -d "$OUTPUT_DIR" ]]; then
        log INFO "Eliminando directorio de salida..."
        rm -rf "$OUTPUT_DIR"
    fi
    
    log INFO "Limpiando imágenes huérfanas..."
    run_docker image prune -f > /dev/null 2>&1 || true
    
    log SUCCESS "Limpieza completa finalizada."
}

# ----------------------------------------------------------------------------
# PROCESAMIENTO DE ARGUMENTOS
# ----------------------------------------------------------------------------

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -V|--version)
                if [[ -n "${2:-}" ]]; then
                    ASEPRITE_VERSION="$2"
                    shift 2
                else
                    log ERROR "La opción --version requiere un argumento."
                    exit 1
                fi
                ;;
            -S|--skia)
                if [[ -n "${2:-}" ]]; then
                    SKIA_VERSION="$2"
                    shift 2
                else
                    log ERROR "La opción --skia requiere un argumento."
                    exit 1
                fi
                ;;
            -s|--skip-cleanup)
                SKIP_CLEANUP=true
                shift
                ;;
            -c|--clean)
                full_cleanup
                exit 0
                ;;
            -l|--list-versions)
                list_versions
                exit 0
                ;;
            -t|--timeout)
                if [[ -n "${2:-}" ]]; then
                    BUILD_TIMEOUT="$2"
                    shift 2
                else
                    log ERROR "La opción --timeout requiere un argumento."
                    exit 1
                fi
                ;;
            *)
                log ERROR "Opción desconocida: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# FUNCIÓN PRINCIPAL
# ----------------------------------------------------------------------------

main() {
    parse_arguments "$@"
    
    print_banner
    
    # Verificaciones iniciales
    check_architecture
    check_basic_dependencies
    check_docker_permissions
    check_docker_running
    check_docker_buildx
    
    # Configurar versiones
    setup_versions
    
    # Mostrar configuración
    echo ""
    log INFO "Configuración final:"
    log INFO "  - Aseprite: $ASEPRITE_VERSION"
    log INFO "  - Skia: $SKIA_VERSION"
    log INFO "  - Directorio salida: $OUTPUT_DIR"
    log INFO "  - Usando sudo: $NEED_SUDO"
    log INFO "  - Usando buildx: $USE_BUILDX"
    log INFO "  - Timeout: ${BUILD_TIMEOUT}s"
    log INFO "  - Verbose: $VERBOSE"
    echo ""
    
    # Ejecutar pasos de compilación
    check_disk_space
    prepare_directories
    build_docker_image
    extract_files
    verify_files
    generate_run_script
    generate_version_info
    show_summary
    cleanup_docker
    
    log SUCCESS "¡Proceso completado exitosamente!"
}

# ----------------------------------------------------------------------------
# PUNTO DE ENTRADA
# ----------------------------------------------------------------------------
main "$@"