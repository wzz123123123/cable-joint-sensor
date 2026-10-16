#include <jni.h>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <poll.h>
#include <android/log.h>

#define LOG_TAG "ttyS7"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static speed_t toSpeed(jint baudrate) {
    switch (baudrate) {
        case 9600: return B9600;
        case 19200: return B19200;
        case 38400: return B38400;
        case 57600: return B57600;
        case 115200: return B115200;
        default: return B19200;
    }
}

static int descriptorField(JNIEnv *env, jclass fdClass, jfieldID *out) {
    jfieldID field = (*env)->GetFieldID(env, fdClass, "descriptor", "I");
    if (field == NULL) {
        (*env)->ExceptionClear(env);
        field = (*env)->GetFieldID(env, fdClass, "fd", "I");
        if (field == NULL) {
            return -1;
        }
    }
    *out = field;
    return 0;
}

static int fdFromObject(JNIEnv *env, jobject fdObj) {
    if (fdObj == NULL) {
        return -1;
    }
    jclass fdClass = (*env)->GetObjectClass(env, fdObj);
    jfieldID field;
    if (descriptorField(env, fdClass, &field) != 0) {
        return -1;
    }
    return (*env)->GetIntField(env, fdObj, field);
}

JNIEXPORT jobject JNICALL
Java_com_example_sensor_1flutter_NativeSerialPort_open(JNIEnv *env, jclass type,
                                                       jstring path, jint baudrate) {
    (void)path;
    const char *path_utf = "/dev/ttyS7";
    int fd = open(path_utf, O_RDWR | O_NOCTTY);
    if (fd < 0) {
        LOGE("open /dev/ttyS7 failed: %s", strerror(errno));
        return NULL;
    }

    struct termios cfg;
    memset(&cfg, 0, sizeof(cfg));
    if (tcgetattr(fd, &cfg) != 0) {
        LOGE("tcgetattr failed: %s", strerror(errno));
        close(fd);
        return NULL;
    }
    cfmakeraw(&cfg);
    speed_t speed = toSpeed(baudrate);
    cfsetispeed(&cfg, speed);
    cfsetospeed(&cfg, speed);
    cfg.c_cflag |= (CLOCAL | CREAD);
    cfg.c_cflag &= ~PARENB;
    cfg.c_cflag &= ~CSTOPB;
    cfg.c_cflag &= ~CSIZE;
    cfg.c_cflag |= CS8;
    cfg.c_cflag &= ~CRTSCTS;
    cfg.c_iflag &= ~(IXON | IXOFF | IXANY);
    /* 超时交给 poll，不要让 Java FileInputStream 把 0 字节当成 EOF */
    cfg.c_cc[VMIN] = 0;
    cfg.c_cc[VTIME] = 0;
    if (tcsetattr(fd, TCSANOW, &cfg) != 0) {
        LOGE("tcsetattr failed: %s", strerror(errno));
        close(fd);
        return NULL;
    }
    tcflush(fd, TCIOFLUSH);
    LOGI("opened /dev/ttyS7 baud=%d fd=%d", baudrate, fd);

    jclass fdClass = (*env)->FindClass(env, "java/io/FileDescriptor");
    jmethodID init = (*env)->GetMethodID(env, fdClass, "<init>", "()V");
    jobject fdObj = (*env)->NewObject(env, fdClass, init);
    jfieldID field;
    if (descriptorField(env, fdClass, &field) != 0) {
        close(fd);
        return NULL;
    }
    (*env)->SetIntField(env, fdObj, field, fd);
    return fdObj;
}

JNIEXPORT jint JNICALL
Java_com_example_sensor_1flutter_NativeSerialPort_readBytes(JNIEnv *env, jclass type,
                                                           jobject fdObj, jbyteArray buffer,
                                                           jint timeoutMs) {
    int fd = fdFromObject(env, fdObj);
    if (fd < 0 || buffer == NULL) {
        return -1;
    }
    jsize cap = (*env)->GetArrayLength(env, buffer);
    if (cap <= 0) {
        return -1;
    }

    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int pr = poll(&pfd, 1, timeoutMs < 0 ? 100 : timeoutMs);
    if (pr == 0) {
        return 0;
    }
    if (pr < 0) {
        if (errno == EINTR) {
            return 0;
        }
        LOGE("poll failed: %s", strerror(errno));
        return -1;
    }
    if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
        LOGE("poll revents=0x%x", pfd.revents);
        return -1;
    }

    jbyte *bytes = (*env)->GetByteArrayElements(env, buffer, NULL);
    if (bytes == NULL) {
        return -1;
    }
    ssize_t n = read(fd, bytes, (size_t) cap);
    (*env)->ReleaseByteArrayElements(env, buffer, bytes, 0);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            return 0;
        }
        LOGE("read failed: %s", strerror(errno));
        return -1;
    }
    return (jint) n;
}

JNIEXPORT void JNICALL
Java_com_example_sensor_1flutter_NativeSerialPort_close(JNIEnv *env, jclass type,
                                                        jobject fdObj) {
    int fd = fdFromObject(env, fdObj);
    if (fd < 0) {
        return;
    }
    close(fd);
    jclass fdClass = (*env)->GetObjectClass(env, fdObj);
    jfieldID field;
    if (descriptorField(env, fdClass, &field) == 0) {
        (*env)->SetIntField(env, fdObj, field, -1);
    }
    LOGI("closed /dev/ttyS7");
}
