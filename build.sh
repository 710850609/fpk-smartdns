BUILD_VERSION=001
SMARTDNS_LATEST_VERSION="unknown"
SMARTDNS_DOWNLOAD_URL="unknown"
DOWNLOAD_FILE="unknown"
SMARTDNS_VERSION="unknown"
BIN_DIR="smartdns/app/bin"

declare -A PARAMS
# 默认值
PARAMS[build_all]="false"
PARAMS[build_pre]="true"
# arrch64, x86_64
PARAMS[arch]="x86_64"
# 解析 key=value 格式的参数
for arg in "$@"; do
  if [[ "$arg" == *=* ]]; then
    key="${arg%%=*}"
    value="${arg#*=}"
    PARAMS["$key"]="$value"
  else
    # 处理标志参数
    case "$arg" in
      --pre)
        PARAMS[pre]="true"
        ;;
      *)
        echo "忽略未知参数: $arg"
        ;;
    esac
  fi
done

build_all="${PARAMS[build_all]}"
build_pre="${PARAMS[build_pre]}"
arch="${PARAMS[arch]}"
echo "build_all: ${build_all}"
echo "build_pre: ${build_pre}"
echo "arch: ${arch}"


# platform 取值 x86, arm, risc-v, all
platform="all"
if [ "${arch}" == "x86_64" ]; then
    platform="x86"
elif [ "${arch}" == "aarch64" ]; then
    platform="arm"
# elif [ "${arch}" == "linux-riscv64" ]; then
#     platform="risc-v"
#     echo "脚本不支持riscv64"
#     exit 1
else
    echo "不支持的 arch 参数"
    exit 1
fi
echo "设置 platform 为: ${platform}"
echo "---------------------------------------"

get_smartdns_latest_version() {
    local arch_type=$1
    local latest_release=$(curl -s https://api.github.com/repos/pymumu/smartdns/releases/latest)
    if [ -z "$latest_release" ]; then
        echo "获取最新smartdns版本信息失败"
        exit 1
    fi
    # 提取版本号
    local version=$(echo "$latest_release" | jq -r .tag_name | sed 's/^Release//')
    # 提取对应架构的下载地址
    download_url=$(echo "$latest_release" | grep -oP '"browser_download_url": "\K(.*'"$arch_type"'-linux-all\.tar\.gz)"' | sed 's/["]//g')
    # https://github.com/pymumu/smartdns/releases/download/Release47.1/smartdns.1.2025.11.09-1443.x86_64-linux-all.tar.gz
    # https://github.com/pymumu/smartdns/releases/download/Release47.1/smartdns.1.2025.11.09-1443.aarch64-linux-all.tar.gz
    # 检查是否成功获取下载地址
    if [ -z "$download_url" ]; then
        echo "下载smartdns失败"
        exit 1
    fi
    # 将版本号和下载链接存储在全局变量中
    SMARTDNS_LATEST_VERSION="$version"
    SMARTDNS_DOWNLOAD_URL="$download_url"
    echo "smartdns最新版本: $SMARTDNS_LATEST_VERSION"
    echo "smartdns最新版本下载地址: $SMARTDNS_DOWNLOAD_URL"
}

get_smartdns_version() {
    local bin_dir=$BIN_DIR
    if [ -f "${bin_dir}/run-smartdns" ]; then
        local version_output=$("${bin_dir}/run-smartdns" -v 2>&1)
        local version=$(echo "$version_output" | grep -oP 'Release\K(\d+\.\d+)')
        if [ -n "$version" ]; then
            echo "当前smartdns版本: $version"
            SMARTDNS_VERSION="$version"
        else
            echo "无法获取当前smartdns版本"
            exit 1
        fi
    else
        echo "smartdns二进制文件不存在，无法获取版本"
        exit 1
    fi
}

download_smartdns() {
    DOWNLOAD_FILE="smartdns-${arch}.tar.gz"
    if [ "${build_all}" == "all" ] || [ ! -f "${DOWNLOAD_FILE}" ] ; then
        local proxy_url
        # proxy_url="https://gh.llkk.cc"
        if [ -n "$proxy_url" ]; then
            SMARTDNS_DOWNLOAD_URL=${proxy_url}/${SMARTDNS_DOWNLOAD_URL}
        fi
        echo "开始下载: ${SMARTDNS_DOWNLOAD_URL}"
        rm -f "${DOWNLOAD_FILE}"
        wget -O "${DOWNLOAD_FILE}" "${SMARTDNS_DOWNLOAD_URL}"
        if [ ! -f "${DOWNLOAD_FILE}" ]; then
            echo "下载smartdns失败"
            exit 1
        fi
    fi
}

update_app() {
    local bin_dir=$BIN_DIR
    local temp_dir="temp"
    bash -c "rm -rf ${bin_dir}" 2>&1
    bash -c "mkdir -p ${bin_dir}" 2>&1
    bash -c "mkdir -p ${temp_dir}" 2>&1
    echo "开始解压 ${DOWNLOAD_FILE}"
    bash -c "tar -xzf ${DOWNLOAD_FILE} -C ${temp_dir}" 2>&1
    echo "开始复制应用文件"
    bash -c "mv ${temp_dir}/smartdns/usr/local/lib/smartdns/* ${bin_dir}" 2>&1
    bash -c "mv -f ${temp_dir}/smartdns/etc/smartdns/smartdns.conf ${bin_dir}" 2>&1
    bash -c "rm -rf ${temp_dir}" 2>&1
    echo "更新应用文件完成"
    echo "---------------------------------------"
    echo "$(ls -l ${bin_dir})"
    get_smartdns_version
    jq ".[0].items |= map(if .field == \"smartdns_version\" then .initValue = \"$SMARTDNS_VERSION\" else . end)" smartdns/wizard/config > temp.json \
    && mv temp.json smartdns/wizard/config
    echo "更新配置向导中的SmartDNS版本号为: ${SMARTDNS_VERSION}"
}


build_fpk() {
    get_smartdns_version
    local fpk_version="${SMARTDNS_VERSION}-${BUILD_VERSION}"
    if [ "$build_pre" == 'true' ];then 
        cur_time=$(date +"%Y%m%d%H%M%S")
        echo "当前时间：$cur_time"
        fpk_version="${fpk_version}-${cur_time}"
    fi
    sed -i "s|^[[:space:]]*version[[:space:]]*=.*|version=${fpk_version}|" 'smartdns/manifest'
    echo "设置 FPK 版本号为: ${fpk_version}"

    echo "开始打包 fpk"
    if command -v fnpack >/dev/null 2>&1; then
        echo "使用系统已安装的 fnpack 进行打包"
        fnpack build --directory smartdns/  || { echo "打包失败"; exit 1; }
    else
        echo "使用本地 fnpack 脚本进行打包"
        ./fnpack.sh build --directory smartdns || { echo "打包失败"; exit 1; }
    fi 

    fpk_name="smartdns-${arch}-${fpk_version}.fpk"
    rm -f "${fpk_name}"
    mv smartdns.fpk "${fpk_name}"
    echo "打包完成: ${fpk_name}"
}


get_smartdns_latest_version $arch
download_smartdns
update_app
build_fpk

exit 0