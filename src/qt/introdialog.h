#ifndef INTRODIALOG_H
#define INTRODIALOG_H

#include <QDialog>
#include <QString>

namespace Ui {
    class IntroDialog;
}

/** First-run / missing-datadir setup: choose wallet data folder and optional bootstrap. */
class IntroDialog : public QDialog
{
    Q_OBJECT

public:
    explicit IntroDialog(QWidget *parent = 0);
    ~IntroDialog();

    void setDataDirectory(const QString &path);
    QString dataDirectory() const;

    void setBootstrapDirectory(const QString &path);
    /** Absolute path to bootstrap.dat if selected, otherwise empty. */
    QString bootstrapFile() const;

public slots:
    void accept();

private slots:
    void on_dataDirButton_clicked();
    void on_bootstrapButton_clicked();
    void on_bootstrapClearButton_clicked();

private:
    Ui::IntroDialog *ui;
};

#endif // INTRODIALOG_H
