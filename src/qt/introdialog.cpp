#include "introdialog.h"
#include "ui_introdialog.h"

#include "util.h"

#include <QFileDialog>
#include <QDir>
#include <QFileInfo>
#include <QMessageBox>

IntroDialog::IntroDialog(QWidget *parent) :
    QDialog(parent),
    ui(new Ui::IntroDialog)
{
    ui->setupUi(this);
    setWindowTitle(tr("Welcome to POS"));
    ui->statusLabel->clear();

    // Sensible default data directory
    setDataDirectory(QString::fromStdString(GetDefaultDataDir().string()));
}

IntroDialog::~IntroDialog()
{
    delete ui;
}

void IntroDialog::setDataDirectory(const QString &path)
{
    ui->dataDirEdit->setText(QDir::toNativeSeparators(path));
}

QString IntroDialog::dataDirectory() const
{
    return QDir::cleanPath(ui->dataDirEdit->text().trimmed());
}

void IntroDialog::setBootstrapDirectory(const QString &path)
{
    ui->bootstrapEdit->setText(QDir::toNativeSeparators(path));
}

QString IntroDialog::bootstrapFile() const
{
    QString raw = ui->bootstrapEdit->text().trimmed();
    if (raw.isEmpty())
        return QString();

    QFileInfo fi(raw);
    if (fi.isFile())
        return fi.absoluteFilePath();

    if (fi.isDir()) {
        QString candidate = QDir(fi.absoluteFilePath()).filePath("bootstrap.dat");
        if (QFileInfo(candidate).isFile())
            return candidate;
    }
    return QString();
}

void IntroDialog::on_dataDirButton_clicked()
{
    QString start = dataDirectory();
    if (start.isEmpty() || !QDir(start).exists())
        start = QDir::homePath();

    QString dir = QFileDialog::getExistingDirectory(this,
        tr("Select wallet data folder"),
        start,
        QFileDialog::ShowDirsOnly | QFileDialog::DontResolveSymlinks);
    if (!dir.isEmpty())
        setDataDirectory(dir);
}

void IntroDialog::on_bootstrapButton_clicked()
{
    QString start = ui->bootstrapEdit->text().trimmed();
    if (start.isEmpty() || !QDir(start).exists())
        start = dataDirectory().isEmpty() ? QDir::homePath() : dataDirectory();

    QString dir = QFileDialog::getExistingDirectory(this,
        tr("Select folder containing bootstrap.dat"),
        start,
        QFileDialog::ShowDirsOnly | QFileDialog::DontResolveSymlinks);
    if (!dir.isEmpty())
        setBootstrapDirectory(dir);
}

void IntroDialog::on_bootstrapClearButton_clicked()
{
    ui->bootstrapEdit->clear();
    ui->statusLabel->clear();
}

void IntroDialog::accept()
{
    ui->statusLabel->clear();
    QString dataDir = dataDirectory();
    if (dataDir.isEmpty()) {
        ui->statusLabel->setText(tr("Please choose a wallet data folder."));
        return;
    }

    QDir dir(dataDir);
    if (!dir.exists()) {
        if (!QDir().mkpath(dataDir)) {
            ui->statusLabel->setText(tr("Could not create the data folder:\n%1").arg(dataDir));
            return;
        }
    }

    QString bootstrapPath = ui->bootstrapEdit->text().trimmed();
    if (!bootstrapPath.isEmpty()) {
        QFileInfo fi(bootstrapPath);
        QString resolved;
        if (fi.isFile()) {
            resolved = fi.absoluteFilePath();
        } else if (fi.isDir()) {
            resolved = QDir(fi.absoluteFilePath()).filePath("bootstrap.dat");
            if (!QFileInfo(resolved).isFile()) {
                ui->statusLabel->setText(tr("No bootstrap.dat file was found in:\n%1").arg(fi.absoluteFilePath()));
                return;
            }
        } else {
            ui->statusLabel->setText(tr("Bootstrap path does not exist:\n%1").arg(bootstrapPath));
            return;
        }
        Q_UNUSED(resolved);
    }

    QDialog::accept();
}
