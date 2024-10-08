# Start with a pre-configured Alpine image.
FROM ubuntu:latest

RUN apt-get update && apt-get install -y \
    bash \
    libbz2-dev \
    libstdc++6 \
    libgcc1 \
    bzip2 \
    openssl \
    iputils-ping \
    telnet 

#Add newuser safeuser
RUN useradd -m -s /bin/bash safeuser

#Set the working directory to be the home directory
WORKDIR /home/safeuser

# Copy the Fulcrum binary and config file.
COPY bin/Fulcrum Fulcrum
COPY bin/FulcrumAdmin FulcrumAdmin
COPY regtest.conf regtest.conf

# Copia el script al contenedor
COPY setup-openssl.sh /home/safeuser/setup-openssl.sh
COPY openssl.cnf /home/safeuser/openssl.cnf

# Haz que el script sea ejecutable
RUN chmod +x /home/safeuser/setup-openssl.sh

# Ejecuta el script
RUN /home/safeuser/setup-openssl.sh

# Ensure all files are owned by the safeuser user.
RUN chown -R safeuser *

# Dar permisos de ejecución al binario Fulcrum
RUN chmod +x Fulcrum

# Switch to user account.
USER safeuser
# Prep 'sudo' commands.
#RUN echo 'abcd8765' | sudo -S pwd

# Used to hold the Fulcrum database.
RUN mkdir blockchain

# Start Fulcrum server.
#CMD ["tail", "-f", "/dev/null"]
#MD ["./Fulcrum", "regtest.conf"]
CMD ["./Fulcrum", "-D", "./datadir/", "-b", "bitcoind:18443", "-u", "cashu", "-p", "cashu"]


