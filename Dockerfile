###########################################################
# base image, used for build stages and final images
#FROM ubuntu:20.04 as base
FROM phusion/baseimage:focal-1.2.0 as base
# override at runtime to match user that ARM runs as local user
ENV RUN_AS_USER=true
ENV UID=1000
ENV GID=1000
# override at runtime to change makemkv key
ENV MAKEMKV_APP_KEY=""

# local apt/deb proxy for builds
ARG APT_PROXY=""
RUN if [ -n "${APT_PROXY}" ] ; then \
  printf 'Acquire::http::Proxy "%s";' "${APT_PROXY}" \
  > /etc/apt/apt.conf.d/30proxy ; fi

RUN mkdir /opt/arm
WORKDIR /opt/arm

COPY ./scripts/add-ppa.sh /root/add-ppa.sh
# setup Python virtualenv and gnupg/wget for add-ppa.sh
RUN \
  apt update -y && \
  DEBIAN_FRONTEND=noninteractive apt upgrade -y && \
  DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
    gnupg \
    gosu \
    python3 \
    python3-venv \
    udev \
    wget \
    build-essential \
    nano \
    vim \
    lsdvd \
    && \
  DEBIAN_FRONTEND=noninteractive apt clean -y && \
  rm -rf /var/lib/apt/lists/*


###########################################################
# build libdvd in a separate stage, pulls in tons of deps
FROM base as libdvd


RUN \
  bash /root/add-ppa.sh ppa:mc3man/focal6 && \
  apt update -y && \
  DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends libdvd-pkg && \
  DEBIAN_FRONTEND=noninteractive dpkg-reconfigure libdvd-pkg && \
  DEBIAN_FRONTEND=noninteractive apt clean -y && \
  rm -rf /var/lib/apt/lists/*

###########################################################
# build pip reqs for ripper in separate stage
FROM base as dep-ripper
RUN \
  apt update -y && \
  DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
    build-essential \
    libcurl4-openssl-dev \
    libssl-dev \
    python3 \
    python3-dev \
    python3-pyudev \
    python3-wheel \
    udev \
    libudev-dev \
    python3-pip \
    && \
  pip3 install --upgrade pip wheel setuptools \
  && \
  pip3 install pyudev

###########################################################
# install deps for ripper
FROM base as pip-ripper
RUN \
  bash /root/add-ppa.sh ppa:heyarje/makemkv-beta && \
  bash /root/add-ppa.sh ppa:stebbins/handbrake-releases && \
  apt update -y && \
  DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
    abcde \
    eyed3 \
    atomicparsley \
    cdparanoia \
    eject \
    ffmpeg \
    flac \
    glyrc \
    default-jre-headless \
    handbrake-cli \
    libavcodec-extra \
    makemkv-bin \
    makemkv-oss \
    udev \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    libudev-dev \
    python3-wheel \
    python-psutil \
    python3-pyudev \
    && \
    pip3 install wheel \
    && \
    pip3 install --upgrade pip wheel setuptools \
    && \
    pip3 install --upgrade psutil \
    && \
    pip3 install pyudev \
    && \
  DEBIAN_FRONTEND=noninteractive apt clean -y && \
  rm -rf /var/lib/apt/lists/*

# copy just the .deb from libdvd build stage
COPY --from=libdvd /usr/src/libdvd-pkg/libdvdcss2_*.deb /opt/arm

# installing with --ignore-depends to avoid all it's deps
# leaves apt in a broken state so do package install last
RUN DEBIAN_FRONTEND=noninteractive dpkg -i --ignore-depends=libdvd-pkg /opt/arm/libdvdcss2_*.deb

COPY ./docker/requirements/requirements.ripper.txt /requirements.ripper.txt
COPY ./docker/requirements/requirements.ui.txt /requirements.ui.txt
RUN    \
  pip3 install \
    --ignore-installed \
    --prefer-binary \
    -r /requirements.ui.txt \
  && \
  pip3 install \
    --ignore-installed \
    --prefer-binary \
    -r /requirements.ripper.txt
# default directories and configs
RUN \
  mkdir -m 0777 -p /home/arm /home/arm/config /mnt/dev/sr0 /mnt/dev/sr1 /mnt/dev/sr2 /mnt/dev/sr3 /mnt/dev/sr4 && \
  ln -sv /home/arm/config/arm.yaml /opt/arm/arm.yaml && \
  ln -sv /opt/arm/apprise.yaml /home/arm/config/apprise.yaml && \
  echo "/dev/sr0  /mnt/dev/sr0  udf,iso9660  users,noauto,exec,utf8,ro  0  0" >> /etc/fstab  && \
  echo "/dev/sr1  /mnt/dev/sr1  udf,iso9660  users,noauto,exec,utf8,ro  0  0" >> /etc/fstab  && \
  echo "/dev/sr2  /mnt/dev/sr2  udf,iso9660  users,noauto,exec,utf8,ro  0  0" >> /etc/fstab  && \
  echo "/dev/sr3  /mnt/dev/sr3  udf,iso9660  users,noauto,exec,utf8,ro  0  0" >> /etc/fstab  && \
  echo "/dev/sr4  /mnt/dev/sr4  udf,iso9660  users,noauto,exec,utf8,ro  0  0" >> /etc/fstab

# copy ARM source last, helps with Docker build caching
COPY . /opt/arm/

 # Disable SSH
RUN rm -rf /etc/service/sshd /etc/my_init.d/00_regen_ssh_host_keys.sh

RUN mkdir -p /etc/my_init.d
COPY docker/start/start_aaudev.sh /etc/my_init.d/start_udev.sh
COPY docker/start/start_armui.sh /etc/my_init.d/start_armui.sh
#COPY docker/start/start_ripper.sh /etc/my_init.d/start_ripper.sh
COPY docker/start/start_aaudev.sh /etc/my_init.d/start_aaudev.sh
COPY docker/start/docker-entrypoint.sh /etc/my_init.d/docker-entrypoint.sh
COPY docker/udev /etc/init.d/udev

RUN chmod +x /etc/my_init.d/*.sh
RUN chmod +x /opt/arm/arm/ripper/main.py

# Create a user group 'xyzgroup'
RUN addgroup arm
RUN useradd -r -s /bin/bash -g root -G arm -u 1001 arm

RUN chown -R arm:arm /opt/arm
RUN ln -sv /opt/arm/setup/51-automedia-docker.rules /lib/udev/rules.d/
EXPOSE 8080
#VOLUME /home/arm
VOLUME /home/arm/Music
VOLUME /home/arm/logs
VOLUME /home/arm/media
VOLUME /home/arm/config
WORKDIR /home/arm

#ENTRYPOINT ["/opt/arm/scripts/docker-entrypoint.sh"]
#CMD ["python3", "/opt/arm/arm/runui.py"]
CMD ["/sbin/my_init"]

# pass build args for labeling
ARG image_revision=2.5.9
ARG image_created="2022-03-16"

LABEL org.opencontainers.image.source=https://github.com/1337-server/automatic-ripping-machine
LABEL org.opencontainers.image.revision="2.5.9"
LABEL org.opencontainers.image.created="2022-03-16"
LABEL org.opencontainers.image.license=MIT
